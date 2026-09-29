/* Optional mediaserver dlmalloc tracer for the R-LINK QEMU environment.
 *
 * This library intentionally has no libc dependencies beyond symbols already
 * exported by Froyo's libc. It is loaded only by the media-trace init service.
 */

typedef unsigned int size_t;
typedef int ssize_t;
typedef unsigned int uintptr_t;

struct malloc_dispatch {
    void *(*malloc)(size_t);
    void (*free)(void *);
    void *(*calloc)(size_t, size_t);
    void *(*realloc)(void *, size_t);
    void *(*memalign)(size_t, size_t);
};

extern const struct malloc_dispatch *__libc_malloc_dispatch;
extern void dlmalloc_walk_heap(void (*)(const void *, size_t,
                                        const void *, size_t, void *), void *);
extern int open(const char *, int, ...);
extern int access(const char *, int);
extern ssize_t write(int, const void *, size_t);

#define O_WRONLY 1
#define O_APPEND 0x400
#define TRACE_RADIUS 0x10000
#define MAX_TRACED_FREES 64

static int trace_fd = -1;
static void *small_allocation;
static unsigned int free_sequence;
static const struct malloc_dispatch *real_dispatch;
static struct malloc_dispatch trace_dispatch;

static void *trace_malloc(size_t size);
static void trace_free(void *pointer);

static char *put_text(char *out, const char *text)
{
    while (*text) {
        *out++ = *text++;
    }
    return out;
}

static char *put_hex(char *out, uintptr_t value)
{
    static const char hex[] = "0123456789abcdef";
    int shift;

    *out++ = '0';
    *out++ = 'x';
    for (shift = 28; shift >= 0; shift -= 4) {
        *out++ = hex[(value >> shift) & 15];
    }
    return out;
}

static char *put_decimal(char *out, unsigned int value)
{
    char reversed[12];
    int length = 0;

    if (value == 0) {
        *out++ = '0';
        return out;
    }
    while (value) {
        reversed[length++] = (char)('0' + value % 10);
        value /= 10;
    }
    while (length) {
        *out++ = reversed[--length];
    }
    return out;
}

static void emit(const char *buffer, size_t length)
{
    if (trace_fd >= 0) {
        write(trace_fd, buffer, length);
    }
}

static void emit_values(const char *tag, uintptr_t a, uintptr_t b,
                        uintptr_t c, uintptr_t d, uintptr_t e)
{
    char buffer[192];
    char *out = buffer;

    out = put_text(out, "QHEAP ");
    out = put_text(out, tag);
    out = put_text(out, " a="); out = put_hex(out, a);
    out = put_text(out, " b="); out = put_hex(out, b);
    out = put_text(out, " c="); out = put_hex(out, c);
    out = put_text(out, " d="); out = put_hex(out, d);
    out = put_text(out, " e="); out = put_hex(out, e);
    *out++ = '\n';
    emit(buffer, (size_t)(out - buffer));
}

struct walk_filter {
    uintptr_t low;
    uintptr_t high;
};

static void walk_chunk(const void *chunk, size_t chunk_length,
                       const void *user, size_t user_length, void *opaque)
{
    struct walk_filter *filter = (struct walk_filter *)opaque;
    uintptr_t address = (uintptr_t)(user ? user : chunk);

    if (address >= filter->low && address <= filter->high) {
        emit_values(user ? "USED" : "FREE",
                    (uintptr_t)chunk, chunk_length,
                    (uintptr_t)user, user_length,
                    *(const unsigned int *)((const char *)chunk + 4));
    }
}

__attribute__((constructor)) static void heaptrace_init(void)
{
    trace_fd = open("/data/local/tmp/mediaserver-heaptrace.log",
                    O_WRONLY | O_APPEND, 0);
    real_dispatch = __libc_malloc_dispatch;
    trace_dispatch = *real_dispatch;
    trace_dispatch.malloc = trace_malloc;
    trace_dispatch.free = trace_free;
    __libc_malloc_dispatch = &trace_dispatch;
    emit_values("INIT", (uintptr_t)&heaptrace_init,
                (uintptr_t)real_dispatch->malloc,
                (uintptr_t)real_dispatch->free, 0, 0);
}

__attribute__((destructor)) static void heaptrace_fini(void)
{
    if (__libc_malloc_dispatch == &trace_dispatch) {
        __libc_malloc_dispatch = real_dispatch;
    }
}

static void *trace_malloc(size_t size)
{
    void *result = real_dispatch->malloc(size);

    /* MPEG4Extractor's wrapped size+1 allocation reaches malloc as zero on
     * this 32-bit build. Snapshot only when explicitly armed, and before
     * readAt mutates neighboring chunks. */
    if (size <= 1 && result &&
        access("/data/local/tmp/mediaserver-heaptrace.arm", 0) == 0) {
        struct walk_filter filter;

        small_allocation = result;
        free_sequence = 0;
        emit_values("SMALL_ALLOC", (uintptr_t)result, size,
                    ((unsigned int *)result)[-2],
                    ((unsigned int *)result)[-1],
                    (uintptr_t)__builtin_return_address(0));
        filter.low = (uintptr_t)result - TRACE_RADIUS;
        filter.high = (uintptr_t)result + TRACE_RADIUS;
        emit_values("WALK_BEGIN", filter.low, filter.high, 0, 0, 0);
        dlmalloc_walk_heap(walk_chunk, &filter);
        emit_values("WALK_END", filter.low, filter.high, 0, 0, 0);
    }
    return result;
}

static void trace_free(void *pointer)
{
    if (small_allocation && pointer && free_sequence < MAX_TRACED_FREES) {
        char buffer[48];
        char *out = buffer;

        ++free_sequence;
        out = put_text(out, "QHEAP FREE_SEQUENCE ");
        out = put_decimal(out, free_sequence);
        *out++ = '\n';
        emit(buffer, (size_t)(out - buffer));
        emit_values(pointer == small_allocation ? "SMALL_FREE" : "POST_FREE",
                    (uintptr_t)pointer,
                    ((unsigned int *)pointer)[-2],
                    ((unsigned int *)pointer)[-1],
                    (uintptr_t)__builtin_return_address(0),
                    ((unsigned int *)pointer)[0]);
    }
    real_dispatch->free(pointer);
}
