#include <cassert>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include "nn-executor.hpp"

// Memory ordering for the executor barrier atomics. With DL_ATOMIC_OPT the
// barrier uses acquire/release semantics (cheaper than the default
// sequentially-consistent ordering, which lowers to full memory barriers on
// ARM); without the gate everything stays seq_cst, matching the original
// behavior exactly.
#if defined(DL_ATOMIC_OPT)
    #define DL_MO_ACQUIRE std::memory_order_acquire
    #define DL_MO_RELEASE std::memory_order_release
    #define DL_MO_ACQ_REL std::memory_order_acq_rel
    #define DL_MO_RELAXED std::memory_order_relaxed
#else
    #define DL_MO_ACQUIRE std::memory_order_seq_cst
    #define DL_MO_RELEASE std::memory_order_seq_cst
    #define DL_MO_ACQ_REL std::memory_order_seq_cst
    #define DL_MO_RELAXED std::memory_order_seq_cst
#endif

// DL_WFE: the inter-step barrier waits with WFE and the releasing thread
// broadcasts SEV (ARM), or waits with PAUSE (x86). WFE parks the core in a
// low-power state until an event arrives, instead of burning cycles in the
// spin loop. Without the gate the barrier is the original raw spin.
#if defined(DL_WFE) && (defined(__aarch64__) || defined(__arm__))
    #define DL_BARRIER_WAIT() asm volatile("wfe" ::: "memory")
    #define DL_BARRIER_WAKE() asm volatile("sev" ::: "memory")
#elif defined(DL_WFE) && (defined(__x86_64__) || defined(__i386__))
    #define DL_BARRIER_WAIT() asm volatile("pause" ::: "memory")
    #define DL_BARRIER_WAKE()
#else
    #define DL_BARRIER_WAIT()
    #define DL_BARRIER_WAKE()
#endif

// DL_PERSISTENT_POOL: worker threads are spawned once in the constructor and
// reused for every forward() call, instead of pthread_create/pthread_join per
// call. The pool's own wait sites (between forward() calls) always relax the
// core, independent of DL_WFE.
#if defined(DL_PERSISTENT_POOL)
    #if defined(__aarch64__) || defined(__arm__)
        #define DL_POOL_WAIT() asm volatile("wfe" ::: "memory")
        #define DL_POOL_WAKE() asm volatile("sev" ::: "memory")
    #elif defined(__x86_64__) || defined(__i386__)
        #define DL_POOL_WAIT() asm volatile("pause" ::: "memory")
        #define DL_POOL_WAKE()
    #else
        #define DL_POOL_WAIT()
        #define DL_POOL_WAKE()
    #endif
#endif

#define PIPE_ALIGNMENT 64

static NnByte *allocAlignedPipe(NnSize size) {
    NnByte *pipe;
#ifdef _WIN32
    pipe = (NnByte *)_aligned_malloc(size, PIPE_ALIGNMENT);
    if (pipe == NULL)
        throw std::runtime_error("_aligned_malloc failed");
#else
    if (posix_memalign((void **)&pipe, PIPE_ALIGNMENT, size) != 0)
        throw std::runtime_error("posix_memalign failed");
#endif
    return pipe;
}

static void releaseAlignedPipe(NnByte *pipe) {
#ifdef _WIN32
    _aligned_free(pipe);
#else
    free(pipe);
#endif
}

void NnFakeNodeSynchronizer::sync(NnUint segmentIndex, NnUint nThreads, NnUint threadIndex) {
    // Nothing
}

NnNetExecution::NnNetExecution(NnUint nThreads, NnNetConfig *netConfig) {
    this->nThreads = nThreads;
    this->nBatches = netConfig->nBatches;
    this->nPipes = netConfig->nPipes;
    this->batchSize = 0; // This value must be overwritten before calling forward

    pipes = new NnByte *[netConfig->nPipes];
    for (NnUint pipeIndex = 0; pipeIndex < netConfig->nPipes; pipeIndex++) {
        NnPipeConfig *pipeConfig = &netConfig->pipes[pipeIndex];
        NnByte *pipe = allocAlignedPipe(pipeConfig->size.nBytes);
        std::memset(pipe, 0, pipeConfig->size.nBytes);
        pipes[pipeIndex] = pipe;
    }
}

NnNetExecution::~NnNetExecution() {
    for (NnUint pipeIndex = 0; pipeIndex < nPipes; pipeIndex++)
        releaseAlignedPipe(pipes[pipeIndex]);
    delete[] pipes;
}

void NnNetExecution::setBatchSize(NnUint batchSize) {
    assert(batchSize <= nBatches);
    this->batchSize = batchSize;
}

NnExecutorDevice::NnExecutorDevice(NnDevice *device, int segmentFrom, int segmentTo) {
    this->device = std::unique_ptr<NnDevice>(device);
    this->segmentFrom = segmentFrom;
    this->segmentTo = segmentTo;
}

NnExecutorException::NnExecutorException(const std::string message)
    : std::runtime_error(message)
{}

#if defined(DL_PERSISTENT_POOL)
// Defined later in this file.
static void *executorWorkerLoop(void *arg);
#endif

NnExecutor::NnExecutor(NnNetConfig *netConfig, NnNodeConfig *nodeConfig, std::vector<NnExecutorDevice> *devices, NnNetExecution *netExecution, NnNodeSynchronizer *synchronizer, bool benchmark)
    : segments(nodeConfig->nSegments), steps()
{
    NnUint maxNThreads = 0;
    for (NnExecutorDevice &d : *devices) {
        if (d.device->maxNThreads() > maxNThreads)
            maxNThreads = d.device->maxNThreads();
    }
    if (netExecution->nThreads > maxNThreads)
        throw std::invalid_argument("This configuration supports max " + std::to_string(maxNThreads) + " threads");

    this->netExecution = netExecution;
    this->nodeConfig = nodeConfig;

    bool useSynchronizer = netConfig->nNodes > 1;
    for (NnUint segmentIndex = 0; segmentIndex < nodeConfig->nSegments; segmentIndex++) {
        NnDevice *device = nullptr;
        for (NnExecutorDevice &d : *devices) {
            if (
                (d.segmentFrom == -1 && d.segmentTo == -1) ||
                (segmentIndex >= d.segmentFrom && segmentIndex <= d.segmentTo)
            ) {
                device = d.device.get();
                break;
            }
        }
        if (device == nullptr)
            throw std::invalid_argument("Cannot locate device for segment " + std::to_string(segmentIndex));

        NnSegmentConfig *segmentConfig = &nodeConfig->segments[segmentIndex];
        if (segmentConfig->nOps > 0) {
            NnDeviceSegment *segment = device->createSegment(segmentIndex);
            segments[segmentIndex] = std::unique_ptr<NnDeviceSegment>(segment);

            for (NnUint opIndex = 0; opIndex < segmentConfig->nOps; opIndex++)
                steps.push_back(NnExecutorStep{ STEP_EXECUTE_OP, segment, opIndex, &segmentConfig->ops[opIndex] });
        }
        if (useSynchronizer && segmentConfig->nSyncs > 0)
            steps.push_back(NnExecutorStep{ STEP_SYNC_NODES, nullptr, segmentIndex, nullptr });
    }

    steps.shrink_to_fit();

    context.nThreads = netExecution->nThreads;
    context.synchronizer = synchronizer;
    context.nSteps = (NnUint)steps.size();
    context.steps = steps.data();
    if (benchmark)
        context.timer = new Timer();
    else
        context.timer = nullptr;

    threads = new NnExecutorThread[netExecution->nThreads];
    for (NnUint threadIndex = 0; threadIndex < netExecution->nThreads; threadIndex++) {
        NnExecutorThread *thread = &threads[threadIndex];
        thread->threadIndex = threadIndex;
        thread->context = &context;
    }

#if defined(DL_PERSISTENT_POOL)
    // Spawn N-1 worker threads once and reuse them for every forward() call.
    // Thread 0 is the calling thread and is not created here.
    context.generation.store(0, DL_MO_RELAXED);
    context.workersDone.store(0, DL_MO_RELAXED);
    context.shutdown.store(false, DL_MO_RELAXED);
    for (NnUint threadIndex = 1; threadIndex < netExecution->nThreads; threadIndex++) {
        int result = pthread_create(&threads[threadIndex].handler, NULL, (PthreadFunc)executorWorkerLoop, (void *)&threads[threadIndex]);
        assert(result == 0 && "Failed to create worker thread");
    }
#endif
}

NnExecutor::~NnExecutor() {
#if defined(DL_PERSISTENT_POOL)
    context.shutdown.store(true, std::memory_order_release);
    context.generation.fetch_add(1, std::memory_order_release);
    DL_POOL_WAKE();
    for (NnUint threadIndex = 1; threadIndex < netExecution->nThreads; threadIndex++)
        pthread_join(threads[threadIndex].handler, NULL);
#endif
    if (context.timer != nullptr)
        delete context.timer;
    delete[] threads;
}

void NnExecutor::loadWeight(const char *name, NnUint opIndex, NnSize offset, NnSize nBytes, NnByte *weight) {
    for (NnUint segmentIndex = 0; segmentIndex < nodeConfig->nSegments; segmentIndex++) {
        NnSegmentConfig *segmentConfig = &nodeConfig->segments[segmentIndex];
        for (NnUint i = 0; i < segmentConfig->nOps; i++) {
            NnOpConfig *opConfig = &segmentConfig->ops[i];
            if (opConfig->index == opIndex && std::strcmp(opConfig->name, name) == 0) {
                NnDeviceSegment *segment = segments[segmentIndex].get();
                assert(segment != nullptr);
                segment->loadWeight(i, offset, nBytes, weight);
                return;
            }
        }
    }
    throw std::invalid_argument("Cannot locate op by name: " + std::string(name));
}

inline void executeStep(NnExecutorStep *step, NnUint nThreads, NnExecutorThread *thread, NnExecutorContext *context) {
    if (step->type == STEP_EXECUTE_OP) {
        step->segment->forward(step->arg0, nThreads, thread->threadIndex, context->batchSize);
    } else if (step->type == STEP_SYNC_NODES) {
        context->synchronizer->sync(step->arg0, nThreads, thread->threadIndex);
    } else {
        throw std::invalid_argument("Unsupported step type");
    }
}

static inline void *executorThreadHandler(void *arg) {
    NnExecutorThread *thread = (NnExecutorThread *)arg;
    NnExecutorContext *context = thread->context;
    NnUint nThreads = context->nThreads;
    NnUint doneCount = nThreads - 1;

    while (context->isAlive.load(DL_MO_ACQUIRE)) {
        const unsigned int currentStepIndex = context->currentStepIndex.load(DL_MO_ACQUIRE);
        if (currentStepIndex == context->nSteps)
            break;

        NnExecutorStep *step = &context->steps[currentStepIndex];
        try {
            executeStep(step, nThreads, thread, context);
        } catch (const std::runtime_error &e) {
            context->isAlive.store(false, DL_MO_RELEASE);
            printf("🚨 Execution error: %s\n", e.what());
            break;
        }

        NnUint currentCount = context->doneThreadCount.fetch_add(1, DL_MO_ACQ_REL);
        if (currentCount == doneCount) {
            if (context->timer != nullptr) {
                NnUint time = context->timer->elapsedMicroseconds();
                context->totalTime[step->type] += time;
                context->timer->reset();
            }

            context->doneThreadCount.store(0, DL_MO_RELAXED);
            context->currentStepIndex.fetch_add(1, DL_MO_RELEASE);
            DL_BARRIER_WAKE();
        } else {
            while (
                context->currentStepIndex.load(DL_MO_ACQUIRE) == currentStepIndex &&
                context->isAlive.load(DL_MO_ACQUIRE)
            ) {
                DL_BARRIER_WAIT();
            }
        }
    }
    return nullptr;
}

#if defined(DL_PERSISTENT_POOL)
// Worker thread main loop: waits for a new forward() call (generation bump),
// runs the step loop, signals completion, repeats. The thread's lifetime spans
// the whole NnExecutor, saving one pthread_create + pthread_join per
// forward() call.
static void *executorWorkerLoop(void *arg) {
    NnExecutorThread *thread = (NnExecutorThread *)arg;
    NnExecutorContext *context = thread->context;
    unsigned long long lastGen = 0;

    while (true) {
        unsigned long long gen;
        for (;;) {
            gen = context->generation.load(std::memory_order_acquire);
            if (gen != lastGen) break;
            if (context->shutdown.load(std::memory_order_acquire)) return nullptr;
            DL_POOL_WAIT();
        }
        if (context->shutdown.load(std::memory_order_acquire)) return nullptr;
        lastGen = gen;

        executorThreadHandler((void *)thread);

        context->workersDone.fetch_add(1, std::memory_order_release);
        // Wake thread 0 waiting in forward() for workersDone.
        DL_POOL_WAKE();
    }
}
#endif

void NnExecutor::forward() {
    assert(netExecution->batchSize > 0);

    NnUint nThreads = netExecution->nThreads;
    context.isAlive.exchange(true);
    context.currentStepIndex.exchange(0);
    context.doneThreadCount.exchange(0);
    context.batchSize = netExecution->batchSize;

    if (context.timer != nullptr) {
        std::memset(context.totalTime, 0, sizeof(context.totalTime));
        context.timer->reset();
    }

#if defined(DL_PERSISTENT_POOL)
    context.workersDone.store(0, DL_MO_RELAXED);
    // Release the workers waiting in executorWorkerLoop; they re-check the
    // generation counter with acquire semantics, which makes the resets above
    // visible to them.
    context.generation.fetch_add(1, std::memory_order_release);
    DL_POOL_WAKE();

    executorThreadHandler((void *)&threads[0]);

    const NnUint expectedDone = nThreads - 1;
    while (context.workersDone.load(std::memory_order_acquire) < expectedDone)
        DL_POOL_WAIT();
#else
    NnUint threadIndex;
    for (threadIndex = 1; threadIndex < nThreads; threadIndex++) {
        int result = pthread_create(&threads[threadIndex].handler, NULL, (PthreadFunc)executorThreadHandler, (void *)&threads[threadIndex]);
        assert(result == 0 && "Failed to create thread");
    }
    executorThreadHandler((void *)&threads[0]);
    for (threadIndex = 1; threadIndex < nThreads; threadIndex++)
        pthread_join(threads[threadIndex].handler, NULL);
#endif

    if (!context.isAlive.load(DL_MO_ACQUIRE))
        throw NnExecutorException("Execution failed in one of the threads");
}

NnUint NnExecutor::getTotalTime(NnExecutorStepType type) {
    assert((NnUint)type < N_STEP_TYPES);
    return context.totalTime[type];
}
