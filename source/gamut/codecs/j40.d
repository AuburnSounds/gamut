// J40: Independent, self-contained JPEG XL decoder
// Kang Seonghoon, version 2270 (2022-09), Public Domain
// https://github.com/lifthrasiir/j40
//
// This is a decoder for JPEG XL (ISO/IEC 18181) image format. It intends to be a fully compatible
// reimplementation to the reference implementation, libjxl, and also serves as a verification that
// the specification allows for an independent implementation besides from libjxl.
//
// The following is a simple but complete converter from JPEG XL to Portable Arbitrary Map format:
//
// Translated to D by Guillaume Piolat (2024), still with same licence.
// It has the same limitations as j40.h 
module gamut.codecs.j40;

version(decodeJXL):

import core.stdc.stdint: SIZE_MAX, uintptr_t;
import core.stdc.stdio: snprintf;
import core.stdc.stdlib: free, malloc, realloc, calloc, qsort;
import core.stdc.string: memset, memcpy, memcmp, memmove;
import core.stdc.math: isfinite, fabs, ldexpf, powf, hypotf, fabsf, cbrtf;
import core.bitop: bsr;
import inteli.emmintrin: _mm_malloc, _mm_free;

//version = j40_debug;

version(j40_debug)
{
    import core.stdc.stdio : printf;
}

nothrow:
@nogc:

enum J40_VERSION = 2270; // (fractional gregorian year - 2000) * 100, with a liberal rounding


////////////////////////////////////////////////////////////////////////////////
// public API

// an internal error type. non-zero indicates a different error condition.
// user callbacks can also emit error codes, which should not exceed `J40_MIN_RESERVED_ERR`.
// it can be interpreted as a four-letter code, but such encoding is not guaranteed.
alias j40_err = uint;

enum j40_err J40_MIN_RESERVED_ERR  = 1 << 24; // anything below this can be used freely

struct j40_image
{
    // either J40__IMAGE_MAGIC, (J40__IMAGE_ERR_MAGIC ^ origin) or (J40__IMAGE_OPEN_ERR_MAGIC ^ origin)
    uint magic;
    union j40_image_state
    {
        j40__inner *inner;  // if magic == J40__IMAGE_MAGIC
        j40_err err;        // if magic == J40__IMAGE_ERR_MAGIC
        int saved_errno;    // if magic == J40__IMAGE_OPEN_ERR_MAGIC (err is assumed to be `open`)
    }
    j40_image_state u;
}

struct j40_frame
{
    uint magic; // should be J40__FRAME_MAGIC or J40__FRAME_ERR_MAGIC
    uint reserved;
    j40__inner *inner;
}

extern(C)
{
    alias j40_memory_free_func = void function(void *data);
}

// pixel formats
//rsvd: J40_U8                  0x0f0f
//rsvd: J40_U16                 0x0f17
//rsvd: J40_U32                 0x0f1b
//rsvd: J40_U64                 0x0f1d
//rsvd: J40_F32                 0x0f1e
//rsvd: J40_U8X3                0x0f27
//rsvd: J40_U16X3               0x0f2b
//rsvd: J40_U32X3               0x0f2d
//rsvd: J40_F32X3               0x0f2e
enum J40_U8X4                = 0x0f33;
//rsvd: J40_U16X4               0x0f35
//rsvd: J40_U32X4               0x0f36
//rsvd: J40_F32X4               0x0f39

// color types
//rsvd: J40_RED                 0x170f
//rsvd: J40_GREEN               0x1717
//rsvd: J40_BLUE                0x171b
//rsvd: J40_LUMI                0x171d
//rsvd: J40_ALPHA               0x171e
//rsvd: J40_CYAN                0x1727
//rsvd: J40_YELLOW              0x172b
//rsvd: J40_MAGENTA             0x172d
//rsvd: J40_BLACK               0x172e
//rsvd: J40_JPEG_Y              0x1733
//rsvd: J40_JPEG_CB             0x1735
//rsvd: J40_JPEG_CR             0x1736
//rsvd: J40_OPSIN_X             0x1739
//rsvd: J40_OPSIN_Y             0x173a
//rsvd: J40_OPSIN_B             0x173c
//rsvd: J40_RED_BEFORE_CT       0x1747
//rsvd: J40_GREEN_BEFORE_CT     0x174b
//rsvd: J40_BLUE_BEFORE_CT      0x174d
//rsvd: J40_RGB                 0x174e
//rsvd: J40_BGR                 0x1753
enum J40_RGBA                 = 0x1755;
//rsvd: J40_ARGB                0x1756
//rsvd: J40_BGRA                0x1759
//rsvd: J40_ABGR                0x175a

alias j40_u8x4 = ubyte[4];
alias j40_f32x4 = float[4];

struct j40_pixels_u8x4
{
    int width, height;
    int stride_bytes;
    const(void)* data;
}

////////////////////////////////////////////////////////////////////////////////
//////////////////////// internal code starts from here ////////////////////////
////////////////////////////////////////////////////////////////////////////////

private:

// comment convention:
// "SPEC" comments are used for incorrect, ambiguous or misleading specification issues.
// "TODO spec" comments are roughly same, but not yet fully confirmed & reported.

// Note: J40__INIT means zero-initialization, but we use .init and it has been done carefully.
//       Warning, as j40.h also uses a .init field! (named init_ here).

// rule of thumb: sparingly use them, except for the obvious error cases
version(LDC)
{
    import ldc.intrinsics;
    bool J40_LIKELY(bool b) { return llvm_expect!bool(b, true); }
    bool J40_UNLIKELY(bool b) { return llvm_expect!bool(b, false); }

    bool J40_UNLIKELY(uint err) { return llvm_expect!bool(err != 0, false); }
}
else
{
    bool J40_LIKELY(bool b) { return b; }
    bool J40_UNLIKELY(bool b) { return b; }
    bool J40_UNLIKELY(uint err) { return err != 0; }
}
alias J40_MALLOC  = malloc;
alias J40_CALLOC  = calloc;
alias J40_REALLOC = realloc;
alias J40_FREE    = free;

////////////////////////////////////////////////////////////////////////////////
// state

// bit and logical buffer. this is most frequently accessed and thus available without indirection.
//
// the bit buffer (`nbits` least significant bits of `bits`) is the least significant bits available
// for decoding, and the logical buffer [ptr, end) corresponds to subsequent bits.
// the logical buffer is guaranteed to be all in the codestream (which is not always true if
// the file uses a container).
//
// when the bit buffer has been exhausted the next byte from the logical buffer is consumed and
// appended at the *top* of the bit buffer. when the logical buffer has been exhausted
// higher layers (first backing buffer, then container, and finally source) should be consulted.
struct j40__bits_st // zero-initialized 
{
    int nbits   = 0; // [0, 64]
    ulong bits  = 0;
    ubyte* ptr  = null;
    ubyte* end  = null;
}

// a common context ("state") for all internal functions.
// this bears a strong similarity with `struct j40__inner` type in the API layer which would be
// introduced much later. there are multiple reasons for this split:
// - `j40__st` is designed to be in the stack, so it doesn't take up much stack space.
// - `j40__st` allows for partial initialization of subsystems, which makes testing much easier.
// - `j40__st` only holds things relevant to decoding, while `j40__inner` has API contexts.
// - there can be multiple `j40__st` for multi-threaded decoding.
struct j40__st // zero-initialized
{
    j40_err err = 0; // first error code encountered, or 0
    deprecated int saved_errno = 0;
    int cannot_retry = 0; // a fatal error was encountered and no more additional input will fix it

    // different subsystems make use of additional contexts, all accessible from here.
    j40__bits_st bits; // very frequently accessed, thus inlined here
    j40__source_st *source = null;
    j40__container_st *container = null;
    j40__buffer_st *buffer = null;
    j40__image_st *image = null;
    j40__frame_st *frame = null;
    j40__lf_group_st *lf_group = null;
    const(j40__limits) *limits = null;
}

////////////////////////////////////////////////////////////////////////////////
// error handling and memory allocation

void J40__UNREACHABLE()
{
    assert(0);
}

// A sort of fourCC
uint J40__4(string s)
{
    assert(s.length == 4);
    return cast(j40_err) ((cast(uint) (s)[0] << 24) 
               | (cast(uint) (s)[1] << 16) 
               | (cast(uint) (s)[2] << 8) 
               | cast(uint) (s)[3]);
}

j40_err J40__ERR(j40__st* st, string s)
{
    return j40__set_error(st, J40__4(s));
}

string J40__SHOULD(string cond, string s)()
{
    enum string code =
    `{
        if (J40_UNLIKELY(st.err)) 
            goto J40__ON_ERROR;
        if (J40_UNLIKELY((` ~ cond ~ `cond) == 0)) 
        { 
            j40__set_error(st, J40__4(` ~ s ~ `)); 
            goto J40__ON_ERROR; 
        }
    }`;
    return code;
}

/*

#define J40__RAISE(s) do { j40__set_error(st, J40__4(s)); goto J40__ON_ERROR; } while (0)
#define J40__RAISE_DELAYED() do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0)
*/
template J40__TRY(string expr)
{
    enum string J40__TRY = `
    {
        if (J40_UNLIKELY(` ~ expr ~ `)) { assert(st.err); goto J40__ON_ERROR; }
    }`;
}

// this *should* use casting because C/C++ don't allow comparison between pointers
// that came from different arrays at all: https://stackoverflow.com/a/39161283
bool J40__INBOUNDS(void* ptr, void* start, size_t size)
{
    return (cast(uintptr_t) (ptr) - cast(uintptr_t) (start) <= cast(uintptr_t) (size));
}


/*
#define J40__TRY_MALLOC(type, ptr, num) \
    do { \
        type *newptr = (type*) j40__malloc(num, sizeof(type)); \
        J40__SHOULD(*(ptr) = newptr, "!mem"); \
    } while (0)

#define J40__TRY_CALLOC(type, ptr, num) \
    do { \
        type *newptr = (type*) j40__calloc(num, sizeof(type)); \
        J40__SHOULD(*(ptr) = newptr, "!mem"); \
    } while (0)

#define J40__TRY_REALLOC64(type, ptr, len, cap) \
    do { \
        type *newptr = (type*) j40__realloc64(st, *(ptr), sizeof(type), len, cap); \
        if (J40_LIKELY(newptr)) *(ptr) = newptr; else goto J40__ON_ERROR; \
    } while (0)

*/

j40_err j40__set_error(j40__st *st, j40_err err) 
{
    if (err != J40__4("shrt")) st.cannot_retry = 1;
    if (!st.err) st.err = err;
    return err;
}

void* j40__malloc(size_t num, size_t size) 
{
    if (size == 0 || num > SIZE_MAX / size) return null;
    return J40_MALLOC(num * size);
}

void* j40__calloc(size_t num, size_t size) 
{
    return J40_CALLOC(num, size);
}

void* j40__realloc32(j40__st *st, void *ptr, size_t itemsize, int len, int *cap) 
{
    void *newptr;
    uint newcap;
    size_t newsize;
    assert(len >= 0);
    if (len <= *cap) return ptr;
    newcap = cast(uint) *cap * 2;
    if (newcap > cast(uint) INT32_MAX) newcap = cast(uint) INT32_MAX;
    if (newcap < cast(uint) len) newcap = cast(uint) len;

    if (J40_UNLIKELY(st.err)) goto err;
    if (J40_UNLIKELY(!(newcap <= SIZE_MAX / itemsize))) 
    { 
        j40__set_error(st, J40__4("!mem")); 
        goto err; 
    }
    newsize = cast(size_t) (itemsize * newcap);
    if (J40_UNLIKELY(st.err)) goto err; // <-- This can never happen
    newptr = ptr ? J40_REALLOC(ptr, newsize) : J40_MALLOC(newsize);
    if (J40_UNLIKELY(newptr is null))
    { 
        j40__set_error(st, J40__4("!mem")); 
        goto err; 
    }
    *cap = cast(int) newcap;
    return newptr;
err:
    return null;
}

void *j40__realloc64(j40__st *st, void *ptr, size_t itemsize, long len, long *cap) 
{
    void *newptr;
    ulong newcap;
    size_t newsize;
    assert(len >= 0);
    if (len <= *cap) return ptr;
    newcap = cast(ulong) *cap * 2;
    if (newcap > cast(ulong) INT64_MAX) newcap = cast(ulong) INT64_MAX;
    if (newcap < cast(ulong) len) newcap = cast(ulong) len;
    if (J40_UNLIKELY(st.err)) goto err;
    if (J40_UNLIKELY(!(newcap <= SIZE_MAX / itemsize)))
    { 
        j40__set_error(st, J40__4("!mem")); 
        goto err; 
    }

    newsize = cast(size_t) (itemsize * newcap);

    if (J40_UNLIKELY(st.err)) goto err; // <-- This can never happen
    newptr = ptr ? J40_REALLOC(ptr, newsize) : J40_MALLOC(newsize);
    if (J40_UNLIKELY(newptr is null))
    { 
        j40__set_error(st, J40__4("!mem")); 
        goto err; 
    }
    *cap = cast(long) newcap;
    return newptr;
err:
    return null;
}

alias j40__free = J40_FREE;

////////////////////////////////////////////////////////////////////////////////
// utility

/*
#define J40__CONCAT_(a,b) a##b
#define J40__CONCAT(a,b) J40__CONCAT_(a,b)
#define J40__CONCAT3(a,b,c) J40__CONCAT(a,J40__CONCAT(b,c))

// `j40__(foo, X)` and its uppercase version is `j40__foo` followed by a macro `J40__V` expanded;
// this greatly simplifies the construction of templated names.
#define J40__PARAMETRIC_NAME_(prefix, x, J40__V) J40__CONCAT3(prefix, x, J40__V)
#define j40__(x, V) J40__PARAMETRIC_NAME_(j40__, x, J40__CONCAT(J40__, V))
#define J40__(x, V) J40__PARAMETRIC_NAME_(J40__, x, J40__CONCAT(J40__, V))

int j40__unpack_signed(int x);
long j40__unpack_signed64(long x);
int j40__ceil_div32(int x, int y);
long j40__ceil_div64(long x, long y);
loat j40__minf(float x, float y);
float j40__maxf(float x, float y);
int j40__surely_nonzero(float x);
*/

int j40__unpack_signed(int x) {
    return cast(int) (x & 1 ? -(x / 2 + 1) : x / 2);
}
long j40__unpack_signed64(long x) {
    return cast(long) (x & 1 ? -(x / 2 + 1) : x / 2);
}

// equivalent to ceil(x / y)
int j40__ceil_div32(int x, int y) { return (x + y - 1) / y; }
long j40__ceil_div64(long x, long y) { return (x + y - 1) / y; }

float j40__minf(float x, float y) { return (x < y ? x : y); }
float j40__maxf(float x, float y) { return (x > y ? x : y); }

// used to guard against division by zero
int j40__surely_nonzero(float x) 
{
    return isfinite(x) && fabs(x) >= 1e-8f;
}

// Scan for most significant set bit.

// How many cleared zeroes before set bit?
int j40__clz32(uint x)
{
    if (x == 0)
        return 32;
    else
        return 31 - bsr(x);
}

// How many cleared zeroes before set bit?
int j40__clz64(ulong x) 
{
    return x >> 32 ? j40__clz32(cast(uint) (x >> 32)) : 32 + j40__clz32(cast(uint) x);
}

// j40__intN and j40__uintN
alias j40__int16 = short;
alias j40__uint16 = ushort;
alias j40__int32 = int;
alias j40__uint32 = uint;
alias j40__int64 = long;
alias j40__uint64 = ulong;

// J40__INTN_MAX and J40__INTN_MIN
enum short INT16_MIN = short.min;
enum short INT16_MAX = short.max;
enum   int INT32_MIN = int.min;
enum   int INT32_MAX = int.max;
enum  long INT64_MIN = long.min;
enum  long INT64_MAX = long.max;

// Define those lazily as they appear



// same to `(a + b) >> 1` but doesn't overflow, useful for tight loops with autovectorization
// https://devblogs.microsoft.com/oldnewthing/20220207-00/?p=106223
short j40__floor_avg16(short x, short y)
{
    return cast(short)(x / 2 + y / 2 + (x & y & 1));
}

int j40__floor_avg32(int x, int y)
{
    return cast(int)(x / 2 + y / 2 + (x & y & 1));
}

template j40__floor_avg(int P)
{
    static if (P == 16)
        alias j40__floor_avg = j40__floor_avg16;
    else
        alias j40__floor_avg = j40__floor_avg32;
}

int j40__abs32(int x) 
{
	return (x < 0) ? -x : x;
}

long j40__abs64(long x) 
{
	return (x < 0) ? -x : x;
}

template j40__abs2P(int P)
{
    static if (P == 16)
        alias j40__abs2P = j40__abs32;
    else
        alias j40__abs2P = j40__abs64;
}

int j40__min32(int x, int y) 
{
    return x < y ? x : y;
}

int j40__max32(int x, int y) 
{
    return x > y ? x : y;
}

long j40__min64(long x, long y) 
{
    return x < y ? x : y;
}

long j40__max64(long x, long y) 
{
    return x > y ? x : y;
}
// addition with overflow check
int j40__add32(int x, int y, int* out_) 
{    
    if (J40_UNLIKELY((x > 0 && y > INT32_MAX - x) || (x < 0 && y < INT32_MIN - x))) 
        return 0;
    
    *out_ = x + y;
    return 1;
}
long j40__add64(long x, long y, long* out_) 
{    
    if (J40_UNLIKELY((x > 0 && y > INT64_MAX - x) || (x < 0 && y < INT64_MIN - x))) 
        return 0;

    *out_ = x + y;
    return 1;
}


/*
int j40__(sub,N)(j40__intN x, j40__intN y, j40__intN *out) {
#ifdef J40_SUB_OVERFLOW
    return !J40_SUB_OVERFLOW(x, y, out);
#else
    return j40__(sub_fallback,N)(x, y, out);
#endif
}
*/

// Multiplication with overflow check
int j40__mul32(int x, int y, int* out_)
{
    if (J40_UNLIKELY(
                     x > 0 ?
                     (y > 0 ? x > INT32_MAX / y : y < INT32_MIN / x) :
                     (y > 0 ? x < INT32_MIN / y : y != 0 && x < INT32_MAX / y)
                     )) 
    {
        return 0;
    } 
    else 
    {
        *out_ = x * y;
        return 1;
    }
}

/*
int j40__mulN(int N)(j40__intN x, j40__intN y, j40__intN *out) 
{
   return j40__(mul_fallback,N)(x, y, out);

}*/
/*

int j40__(sub_fallback,N)(j40__intN x, j40__intN y, j40__intN *out) {
    if (J40_UNLIKELY((y < 0 && x > J40__INTN_MAX + y) || (y > 0 && x < J40__INTN_MIN + y))) {
        return 0;
    } else {
        *out = (j40__intN) (x - y);
        return 1;
    }
}
*/

j40__int32 j40__clamp_add32(j40__int32 x, j40__int32 y) 
{
    j40__int32 out_;
    return j40__add32(x, y, &out_) ? out_ : INT32_MAX;
}

j40__int64 j40__clamp_add64(j40__int64 x, j40__int64 y) 
{
    j40__int64 out_;
    return j40__add64(x, y, &out_) ? out_ : INT64_MAX;
}

j40__int32 j40__clamp_mul32(j40__int32 x, j40__int32 y) 
{
    j40__int32 out_;
    return j40__mul32(x, y, &out_) ? out_ : INT32_MAX;
}


/*

j40__intN j40__(clamp_mul,N)(j40__intN x, j40__intN y) {
    j40__intN out;
    return j40__(mul,N)(x, y, &out) ? out : J40__INTN_MAX;
}

*/


int j40__floor_lg32(uint x) 
{
    return 32 - 1 - j40__clz32(x);
}

int j40__floor_lg64(ulong x) 
{
    return 64 - 1 - j40__clz64(x);
}

template j40__floor_lg2P(int P)
{
    static if (P == 16)
        alias j40__floor_lg2P = j40__floor_lg32;
    else
        alias j40__floor_lg2P = j40__floor_lg64;
}

int j40__ceil_lg32(uint x) 
{
    return x > 1 ? (32 - j40__clz32(x - 1)) : 0;
}

////////////////////////////////////////////////////////////////////////////////
// aligned pointers

void* j40__alloc_aligned(size_t sz,  size_t align_, size_t *outmisalign) 
{
    *outmisalign = 0;
    return _mm_malloc(sz, align_);
}

void j40__free_aligned(void *ptr, size_t align_, size_t misalign) 
{
    assert(misalign == 0);
    _mm_free(ptr);
}

////////////////////////////////////////////////////////////////////////////////
// two-dimensional view

struct j40__view_f32 
{ 
    int logw, logh; 
    float* ptr_; 
}

j40__view_f32 j40__make_view_f32(int logw, 
                                 int logh, 
                                 float* ptr_) 
{
    return j40__view_f32(logw, logh, ptr_);
}

void j40__adapt_view_f32(j40__view_f32 *outv, int logw, int logh) 
{
    assert(outv.logw + outv.logh >= logw + logh);
    outv.logw = logw;
    outv.logh = logh;
}

void j40__reshape_view_f32(j40__view_f32 *outv, int logw, int logh) 
{
    assert(outv.logw + outv.logh == logw + logh);
    outv.logw = logw;
    outv.logh = logh;
}

void j40__copy_view_f32(j40__view_f32* outv, const j40__view_f32 inv) 
{
    int x, y;
    float *outptr = outv.ptr_;
    j40__adapt_view_f32(outv, inv.logw, inv.logh);
    for (y = 0; y < (1 << inv.logh); ++y) 
        for (x = 0; x < (1 << inv.logw); ++x) 
        {
            outptr[y << inv.logw | x] = inv.ptr_[y << inv.logw | x];
        }
}

void j40__transpose_view_f32(j40__view_f32 *outv, const j40__view_f32 inv) 
{
    int x, y;
    float *outptr = outv.ptr_;
    j40__adapt_view_f32(outv, inv.logh, inv.logw);
    for (y = 0; y < (1 << inv.logh); ++y) for (x = 0; x < (1 << inv.logw); ++x) 
    {
        outptr[x << inv.logh | y] = inv.ptr_[y << inv.logw | x];
    }
}

// shuffles columns 01234567 into 02461357 and so on
void j40__oddeven_columns_to_halves_f32(j40__view_f32 *outv, const j40__view_f32 inv) 
{
    int x, y;
    float *outptr = outv.ptr_;
    assert(inv.logw > 0);
    j40__adapt_view_f32(outv, inv.logw, inv.logh);
    for (y = 0; y < (1 << inv.logh); ++y) for (x = 0; x < (1 << inv.logw); ++x) 
    {
        int outx = ((x & 1) << (inv.logw - 1)) | (x >> 1);
        outptr[y << inv.logw | outx] = inv.ptr_[y << inv.logw | x];
    }
}

// shuffles rows 01234567 into 02461357 and so on
void j40__oddeven_rows_to_halves_f32(j40__view_f32 *outv, const j40__view_f32 inv) 
{
    int x, y;
    float *outptr = outv.ptr_;
    assert(inv.logh > 0);
    j40__adapt_view_f32(outv, inv.logw, inv.logh);
    for (y = 0; y < (1 << inv.logh); ++y) 
    {
        int outy = ((y & 1) << (inv.logh - 1)) | (y >> 1);
        for (x = 0; x < (1 << inv.logw); ++x) 
            outptr[outy << inv.logw | x] = inv.ptr_[y << inv.logw | x];
    }
}

float* J40__AT(ref j40__view_f32 view, int x, int y)
{
    assert(0 <= x && x < (1 << view.logw) && 0 <= y && y < (1 << view.logh));
    return view.ptr_ + (y << view.logw | x);
}

debug(j40_debug)
void j40__print_view_f32(j40__view_f32 v, const char *name, const char *file, int line) 
{
    int x, y;
    printf(".--- %s:%d: %s (w=%d h=%d @%p)", file, line, name, 1 << v.logw, 1 << v.logh, v.ptr);
    for (y = 0; y < (1 << v.logh); ++y) {
        printf("\n|");
        for (x = 0; x < (1 << v.logw); ++x) printf(" %f", *J40__AT(v, x, y));
    }
    printf("\n'--- %s:%d\n", file, line);
}

////////////////////////////////////////////////////////////////////////////////
// plane

enum : ubyte
{
    J40__PLANE_U8 = 0x20,
    J40__PLANE_U16 = 0x21,
    J40__PLANE_I16 = 0x41,
    J40__PLANE_U32 = 0x22,
    J40__PLANE_I32 = 0x42,
    J40__PLANE_F32 = 0x62,
    J40__PLANE_EMPTY = 0xe0, // should have width=0 and height=0
}

enum J40__PIXELS_ALIGN = 32;

struct j40__plane // zero-initialized
{
    ubyte type = 0; // 0 means uninitialized (all fields besides from pixels are considered garbage)
    ubyte misalign = 0;
    byte vshift = 0, 
         hshift = 0;
    int width = 0, 
        height = 0;
    int stride_bytes = 0; // the number of *bytes* between each row
    uintptr_t pixels = 0;
}

inout(pixel_t)* J40__TYPED_PIXELS(pixel_t)(inout(j40__plane)* plane, int y, ubyte typeconst)
{
    assert(plane.type == typeconst);
    assert(0 <= y && y < plane.height);
    void* p = cast(void*)(cast(char*) plane.pixels + cast(size_t)plane.stride_bytes * cast(size_t) y);
    assert( ((cast(size_t)p) % J40__PIXELS_ALIGN) == 0);
    return cast(pixel_t*) p;
}

inout(ubyte)* J40__U8_PIXELS(inout(j40__plane)* plane, int y)
{
    return J40__TYPED_PIXELS!ubyte(plane, y, J40__PLANE_U8);
}

inout(short)* J40__I16_PIXELS(inout(j40__plane)* plane, int y) 
{
    return J40__TYPED_PIXELS!short(plane, y, J40__PLANE_I16);
}

inout(int)* J40__I32_PIXELS(inout(j40__plane)* plane, int y)
{
    return J40__TYPED_PIXELS!int(plane, y, J40__PLANE_I32);
}

inout(float)* J40__F32_PIXELS(inout(j40__plane)* plane, int y)
{
    return J40__TYPED_PIXELS!float(plane, y, J40__PLANE_F32);
}

int J40__PLANE_STRIDE(const(j40__plane)* plane)
{
    return plane.stride_bytes >> (plane.type & 31);
}

int J40__PLANE_PIXEL_SIZE(const(j40__plane)* plane)
{
    return 1 << (plane.type & 31);
}

enum {
    J40__PLANE_CLEAR = 1 << 0,
    // for public facing planes, we always add padding to prevent misconception
    J40__PLANE_FORCE_PAD = 1 << 1,
};

j40_err j40__init_plane(j40__st *st, ubyte type, int width, int height, int flags, j40__plane *out_)
{
    int pixel_size = 1 << (type & 31);
    void *pixels;
    int stride_bytes;
    size_t total, misalign;

    out_.type = 0;
    assert(width > 0 && height > 0);

    if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
    if (J40_UNLIKELY(j40__mul32(width, pixel_size, &stride_bytes) == 0)) { j40__set_error(st, J40__4("bigg")); goto J40__ON_ERROR; }

    if (flags & J40__PLANE_FORCE_PAD)
    {
        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
        if (J40_UNLIKELY(j40__add32(stride_bytes, 1, &stride_bytes) == 0)) { j40__set_error(st, J40__4("bigg")); goto J40__ON_ERROR; }
    }

    if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
    if (J40_UNLIKELY(j40__mul32(j40__ceil_div32(stride_bytes, J40__PIXELS_ALIGN), J40__PIXELS_ALIGN, &stride_bytes) == 0)) { j40__set_error(st, J40__4("bigg")); goto J40__ON_ERROR; }
    if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
    if (J40_UNLIKELY((cast(size_t) stride_bytes <= SIZE_MAX / cast(uint) height) == 0)) { j40__set_error(st, J40__4("bigg")); goto J40__ON_ERROR; }

    total = cast(size_t) stride_bytes * cast(size_t) height;

    if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
    if (J40_UNLIKELY((pixels = j40__alloc_aligned(total, J40__PIXELS_ALIGN, &misalign)) == null)) { j40__set_error(st, J40__4("!mem")); goto J40__ON_ERROR; }

    out_.stride_bytes = stride_bytes;
    out_.width = width;
    out_.height = height;
    out_.type = type;
    out_.vshift = out_.hshift = 0;
    out_.misalign = cast(ubyte) misalign;
    out_.pixels = cast(uintptr_t) pixels;
    if (flags & J40__PLANE_CLEAR) memset(pixels, 0, total);

J40__ON_ERROR:
    return st.err;
}

// an empty plane can arise from inverse modular transform, but it can be a bug as well,
// hence a separate function and separate type.
void j40__init_empty_plane(j40__plane *p)
{
    p.type = J40__PLANE_EMPTY;
    p.stride_bytes = 0;
    p.width = p.height = 0;
    p.vshift = p.hshift = 0;
    p.misalign = 0;
    p.pixels = cast(uintptr_t) cast(void*) 0;
}

int j40__plane_all_equal_sized(const(j40__plane[]) planes)
{
    return j40__plane_all_equal_sized(planes.ptr, planes.ptr + planes.length);
}

int j40__plane_all_equal_sized(const(j40__plane)*begin, const(j40__plane)*end) 
{
    j40__plane c;
    int shift_should_match;
    if (begin >= end) return 0; // do not allow edge cases
    c = *begin;
    shift_should_match = (begin.vshift >= 0 && begin.hshift >= 0);
    while (++begin < end) {
        if (c.width != begin.width || c.height != begin.height) return 0;
        // even though the sizes match, different shifts can't be mixed as per the spec
        if (shift_should_match) {
            if (c.vshift >= 0 && c.hshift >= 0 && (c.vshift != begin.vshift || c.hshift != begin.hshift)) return 0;
        }
    }
    return 1;
}

ubyte j40__plane_all_equal_typed(const(j40__plane[]) planes)
{
    return j40__plane_all_equal_typed(planes.ptr, planes.ptr + planes.length);
}

ubyte j40__plane_all_equal_typed(const(j40__plane)*begin, const(j40__plane)*end) 
{
    ubyte type;
    if (begin >= end) return 0;
    type = begin.type;
    while (++begin < end) {
        if (begin.type != type) return 0;
    }
    return type;
}

ubyte j40__plane_all_equal_typed_or_empty(const(j40__plane)* begin, const(j40__plane)* end) 
{
    ubyte type;
    if (begin >= end) return 0;
    type = begin.type;
    while (++begin < end) 
    {
        // allow empty plane to pass this test; if all planes are empty, will return J40__PLANE_EMPTY
        if (type == J40__PLANE_EMPTY) type = begin.type;
        if (begin.type != J40__PLANE_EMPTY && begin.type != type) return 0;
    }
    return type;
}

void j40__free_plane(j40__plane *plane) 
{
    // we don't touch pixels if plane is zero-initialized via memset, because while `plane.type` is
    // definitely zero in this case `(void*) plane.pixels` might NOT be a null pointer!
    if (plane.type && plane.type != J40__PLANE_EMPTY) {
        j40__free_aligned(cast(void*) plane.pixels, J40__PIXELS_ALIGN, plane.misalign);
    }
    plane.width = plane.height = plane.stride_bytes = 0;
    plane.type = 0;
    plane.vshift = plane.hshift = 0;
    plane.misalign = 0;
    plane.pixels = cast(uintptr_t) cast(void*) 0; 
}

////////////////////////////////////////////////////////////////////////////////
// limits

struct j40__limits 
{
    long pixels; // <= 2^61
    int width; // <= 2^31
    int height; // <= 2^30

    ulong icc_output_size; // < 2^63
    int bpp; // <= 64
    int ec_black_allowed;

    int num_extra_channels; // <= 4096
    int needs_modular_16bit_buffers;
    int nb_transforms; // <= 273

    int nb_channels_tr; // # of modular channels after transform
    int tree_depth; // distance between root and leaf nodes
    long zf_pixels; // total # of pixels in a run of zero-duration frames, unlimited if zero
}

static immutable j40__limits J40__MAIN_LV5_LIMITS = j40__limits(
    /*.pixels =*/ 1 << 28, /*.width =*/ 1 << 18, /*.height =*/ 1 << 18,
    /*.icc_output_size =*/ 1u << 22, /*.bpp =*/ 16, /*.ec_black_allowed =*/ 0,
    /*.num_extra_channels =*/ 4, /*.needs_modular_16bit_buffers =*/ 1, /*.nb_transforms =*/ 8,
    /*.nb_channels_tr =*/ 256, /*.tree_depth =*/ 64, /*.zf_pixels =*/ 1 << 28,
);

////////////////////////////////////////////////////////////////////////////////
// input source

extern(C)
{   
    alias j40_source_read_func = int function(ubyte *buf, long fileoff, size_t maxsize, size_t *size, void *data);
    alias j40_source_seek_func = int function(long fileoff, void* data);
    alias j40_source_free_func = void function(void* data); // intentionally same to j40_memory_free_func

}

struct j40__source_st 
{
    j40_source_read_func read_func;
    j40_source_seek_func seek_func;
    j40_source_free_func free_func;
    void *data;
    long fileoff; // absolute file offset, assumed to be 0 at the initialization
    long fileoff_limit; // fileoff can't exceed this; otherwise will behave as if EOF has occurred
}

extern(C)
int j40__memory_source_read(ubyte *buf, long fileoff, size_t maxsize, size_t *size, void *data) 
{
    ubyte *mem = cast(ubyte*) data;
    memcpy(buf, mem + fileoff, maxsize);
    *size = maxsize;
    return 0;
}

j40_err j40__init_memory_source(j40__st *st, ubyte *buf, size_t size, 
                                j40_memory_free_func freefunc, 
                                j40__source_st *source) 
{
    if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
    if (J40_UNLIKELY((size <= cast(ulong) INT64_MAX) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; }
    source.read_func = &j40__memory_source_read;
    source.seek_func = null;
    source.free_func = freefunc;
    source.data = buf;
    source.fileoff = 0;
    source.fileoff_limit = cast(long) size;
J40__ON_ERROR:
    return st.err;
}

j40_err j40__try_read_from_source(j40__st *st, ubyte *buf, long minsize, long maxsize, long *size) 
{
    j40__source_st *source = st.source;
    long read_size = 0;

    *size = 0;

    assert(0 <= minsize && minsize <= maxsize);
    assert(0 <= source.fileoff && source.fileoff <= source.fileoff_limit);

    // clamp maxsize if fileoff_limit is set
    assert(cast(ulong) source.fileoff_limit <= SIZE_MAX); // so maxsize fits in size_t
    if (maxsize > source.fileoff_limit - source.fileoff) {
        maxsize = source.fileoff_limit - source.fileoff;
        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
        // `minsize` bytes can't be read due to virtual EOF
        if (J40_UNLIKELY(!(minsize <= maxsize))) { j40__set_error(st, J40__4("shrt")); goto J40__ON_ERROR; }
    }

    while (read_size < maxsize) 
    {
        size_t added_size;
        if (J40_UNLIKELY(source.read_func(
            buf + read_size, source.fileoff, cast(size_t) (maxsize - read_size), &added_size, source.data
        ))) 
        {
            j40__set_error(st, J40__4("read")); 
            goto J40__ON_ERROR;
        }
        if (added_size == 0) break; // EOF or blocking condition
        if (J40_UNLIKELY(!(added_size <= cast(ulong) INT64_MAX))) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; }
        read_size += cast(long) added_size;
        if (J40_UNLIKELY(!(j40__add64(source.fileoff, cast(long) read_size, &source.fileoff)))) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; }
    }

    if (J40_UNLIKELY(!(read_size >= minsize))) { j40__set_error(st, J40__4("shrt")); goto J40__ON_ERROR; }
    *size = read_size;
J40__ON_ERROR:
    return st.err;
}

j40_err j40__read_from_source(j40__st *st, ubyte *buf, long size) {
    long read_size;
    return j40__try_read_from_source(st, buf, size, size, &read_size);
}

j40_err j40__seek_from_source(j40__st *st, long fileoff) {
    j40__source_st *source = st.source;

    assert(fileoff >= 0);
    if (fileoff == source.fileoff) return 0;

    fileoff = j40__min64(fileoff, source.fileoff_limit);

    // for the memory source read always have the current fileoff so seek is a no-op
    if (source.seek_func) {
        if (J40_UNLIKELY(source.seek_func(fileoff, source.data))) {
            j40__set_error(st, J40__4("seek")); 
            goto J40__ON_ERROR;
        }
    }

    source.fileoff = fileoff;
J40__ON_ERROR:
    return st.err;
}

void j40__free_source(j40__source_st *source) 
{
    if (source.free_func) source.free_func(source.data);
    source.read_func = null;
    source.seek_func = null;
    source.free_func = null;
    source.data = null;
}

////////////////////////////////////////////////////////////////////////////////
// container

struct j40__map
{ 
    long codeoff, fileoff; 
}

alias j40__container_flags = int;
enum : j40__container_flags 
{
    // if set, initial jxl & ftyp boxes have been read
    J40__CONTAINER_CONFIRMED = 1 << 0,

    // currently seen box types, as they have a cardinality and positional requirement
    J40__SEEN_JXLL = 1 << 1, // at most once, before jxlc/jxlp
    J40__SEEN_JXLI = 1 << 2, // at most once
    J40__SEEN_JXLC = 1 << 3, // precludes jxlp, at most once
    J40__SEEN_JXLP = 1 << 4, // precludes jxlc

    // if set, no more jxlc/jxlp boxes are allowed (and map no longer changes)
    J40__NO_MORE_CODESTREAM_BOX = 1 << 5,

    // if set, there is an implied entry for `map[nmap]`. this is required when the last
    // codestream box has an unknown length and thus it extends to the (unknown) end of file.
    J40__IMPLIED_LAST_MAP_ENTRY = 1 << 6,

    // if set, there is no more box past `map[nmap-1]` (or an implied `map[nmap]` if any)
    J40__NO_MORE_BOX = 1 << 7,
}

struct j40__container_st 
{
    int flags; // bitset of `enum j40__container_flags`
    // map[0..nmap) encodes two arrays C[i] = map[i].codeoff and F[i] = map[i].fileoff,
    // so that codestream offsets [C[k], C[k+1]) map to file offsets [F[k], F[k] + (C[k+1] - C[k])).
    // all codestream offsets less than the largest C[i] are 1-to-1 mapped to file offsets.
    //
    // the last entry, in particular F[nmap-1], has multiple interpretations.
    // if the mapping is still being built, F[nmap-1] is the start of the next box to be read.
    // if an implicit map entry flag is set, F[nmap] = L and C[nmap] = C[nmap-1] + (L - F[nmap-1])
    // where L is the file length (which is not directly available).
    j40__map *map;
    int nmap, map_cap;
}

uint j40__u32be(ubyte *p) 
{
    return (cast(uint) p[0] << 24) | (cast(uint) p[1] << 16) | (cast(uint) p[2] << 8) | cast(uint) p[3];
}

// size is < 0 if EOF, or INT64_MAX if the box extends indefinitely until the end of file
j40_err j40__box_header(j40__st *st, uint *type, long *size) 
{
    ubyte[8] buf;
    uint size32;
    ulong size64;
    long headersize;

    if (J40_UNLIKELY(j40__try_read_from_source(st, buf.ptr, 0, 8, &headersize))) { assert(st.err); goto J40__ON_ERROR; }

    if (headersize == 0) {
        *size = -1;
        return 0;
    }

    // if not EOF, the full header should have been read
    if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;    
    if (J40_UNLIKELY(!(headersize == 8))) { j40__set_error(st, J40__4("shrt")); goto J40__ON_ERROR; }

    size32 = j40__u32be(buf.ptr);
    *type = j40__u32be(buf.ptr + 4);
    if (size32 == 0) 
    {
        *size = INT64_MAX;
    } 
    else if (size32 == 1) 
    {
        if (J40_UNLIKELY(j40__read_from_source(st, buf.ptr, 8))) { assert(st.err); goto J40__ON_ERROR; }
        size64 = (cast(ulong) j40__u32be(buf.ptr) << 32) | cast(ulong) j40__u32be(buf.ptr + 4);

        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;    
        if (J40_UNLIKELY(!(size64 >= 16))) { j40__set_error(st, J40__4("boxx")); goto J40__ON_ERROR; }

        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;    
        if (J40_UNLIKELY(!(size64 <= INT64_MAX))) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; }

        *size = cast(long) size64 - 16;
    } else {
        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;    
        if (J40_UNLIKELY(!(size32 >= 8))) { j40__set_error(st, J40__4("boxx")); goto J40__ON_ERROR; }
        *size = cast(long) size32 - 8;
    }

J40__ON_ERROR:
    return st.err;
}

// scans as many boxes as required to map given codestream offset (i.e. the inclusive limit).
// this is done in the best effort basis, so even after this
// `j40__map_codestream_offset(st, wanted_codeoff)` may still fail.
j40_err j40__container(j40__st *st, long wanted_codeoff) {
    static immutable ubyte[12] JXL_BOX = [ // type `JXL `, value 0D 0A 87 0A
        0x00, 0x00, 0x00, 0x0c, 0x4a, 0x58, 0x4c, 0x20, 0x0d, 0x0a, 0x87, 0x0a,
    ];

    static immutable ubyte[20] FTYP_BOX = [ // type `ftyp`, brand `jxl `, version 0, only compatible w/ brand `jxl `
        0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x6a, 0x78, 0x6c, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x6a, 0x78, 0x6c, 0x20,
    ];

    j40__source_st *source = st.source;
    j40__container_st *c = st.container;
    ubyte[32] buf;

    if (!c.map) 
    {
        c.map_cap = 8;
        c.nmap = 1;
        
        j40__map* newptr = cast(j40__map*) j40__malloc(cast(size_t) c.map_cap, j40__map.sizeof);
        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;    
        if (J40_UNLIKELY(!newptr)) { j40__set_error(st, J40__4("!mem")); goto J40__ON_ERROR; }
        c.map = newptr;

        c.map[0].codeoff = c.map[0].fileoff = 0; // fileoff will be updated
    }

    // immediately return if given codeoff is already mappable
    if (c.flags & J40__IMPLIED_LAST_MAP_ENTRY) return 0;
    if (wanted_codeoff < c.map[c.nmap - 1].codeoff) return 0;

    // read the file header (if not yet read) and skip to the next box header
    if (c.flags & J40__CONTAINER_CONFIRMED) 
    {
        if (J40_UNLIKELY(j40__seek_from_source(st, c.map[c.nmap - 1].fileoff))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        }
    } 
    else 
    {
        if (J40_UNLIKELY(j40__seek_from_source(st, 0))) 
        {
            assert(st.err); 
            goto J40__ON_ERROR; 
        }

        if (J40_UNLIKELY(j40__read_from_source(st, buf.ptr, 2))) 
        {
            assert(st.err); 
            goto J40__ON_ERROR; 
        }

        if (buf[0] == 0xff && buf[1] == 0x0a) { // bare codestream
            c.flags = J40__CONTAINER_CONFIRMED | J40__IMPLIED_LAST_MAP_ENTRY;
            return 0;
        }

        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
        if (J40_UNLIKELY(((buf[0] == JXL_BOX[0] && buf[1] == JXL_BOX[1]) == 0)))
        { 
            j40__set_error(st, J40__4( "!jxl")); 
            goto J40__ON_ERROR;
        }

        if (J40_UNLIKELY(j40__read_from_source(st, buf.ptr, JXL_BOX.sizeof + FTYP_BOX.sizeof - 2))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        }

        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
        if (J40_UNLIKELY(memcmp(buf.ptr, JXL_BOX.ptr + 2, JXL_BOX.sizeof - 2) == 0))
        { 
            j40__set_error(st, J40__4( "!jxl")); 
            goto J40__ON_ERROR;
        }

        if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR;
        if (J40_UNLIKELY(((buf[0] == JXL_BOX[0] && buf[1] == JXL_BOX[1]) == 0)))
        { 
            j40__set_error(st, J40__4("!ftyp")); 
            goto J40__ON_ERROR;
        }


        c.flags |= J40__CONTAINER_CONFIRMED;
        c.map[0].fileoff = source.fileoff;
    }

    while (wanted_codeoff >= c.map[c.nmap - 1].codeoff) 
    {
        uint type;
        long size;
        int codestream_box = 0;

        if (J40_UNLIKELY(j40__box_header(st, &type, &size))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        }
        if (size < 0) break;

        // TODO the ordering rule for jxll/jxli may change in the future version of 18181-2
        switch (type) 
        {
        case 0x6a786c6c: // jxll: codestream level
            {
                if (J40_UNLIKELY(st.err)) 
                    goto J40__ON_ERROR;
                if (J40_UNLIKELY((!(c.flags & J40__SEEN_JXLL)) == 0)) 
                { 
                    j40__set_error(st, J40__4("box?")); 
                    goto J40__ON_ERROR; 
                }

                c.flags |= J40__SEEN_JXLL;
                break;
            }

        case 0x6a786c69: // jxli: frame index
            {
                if (J40_UNLIKELY(st.err)) 
                    goto J40__ON_ERROR;
                if (J40_UNLIKELY((!(c.flags & J40__SEEN_JXLI)) == 0)) 
                { 
                    j40__set_error(st, J40__4("box?")); 
                    goto J40__ON_ERROR; 
                }

                c.flags |= J40__SEEN_JXLI;
                break;
            }

        case 0x6a786c63: // jxlc: single codestream
            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((!(c.flags & J40__NO_MORE_CODESTREAM_BOX)) == 0)) 
            { 
                j40__set_error(st, J40__4("box?")); 
                goto J40__ON_ERROR; 
            }
            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((!(c.flags & (J40__SEEN_JXLP | J40__SEEN_JXLC))) == 0)) 
            { 
                j40__set_error(st, J40__4("box?")); 
                goto J40__ON_ERROR; 
            }
            c.flags |= J40__SEEN_JXLC | J40__NO_MORE_CODESTREAM_BOX;
            codestream_box = 1;
            break;

        case 0x6a786c70: // jxlp: partial codestreams
            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((!(c.flags & J40__NO_MORE_CODESTREAM_BOX)) == 0)) 
            { 
                j40__set_error(st, J40__4("box?")); 
                goto J40__ON_ERROR; 
            }
            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((!(c.flags & J40__SEEN_JXLC)) == 0)) 
            { 
                j40__set_error(st, J40__4("box?")); 
                goto J40__ON_ERROR; 
            }
            c.flags |= J40__SEEN_JXLP;
            codestream_box = 1;

            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((size >= 4) == 0)) 
            { 
                j40__set_error(st, J40__4("jxlp")); 
                goto J40__ON_ERROR; 
            }
            if (J40_UNLIKELY(j40__read_from_source(st, buf.ptr, 4))) 
            { 
                assert(st.err); 
                goto J40__ON_ERROR; 
            }

            // TODO the partial codestream index is ignored right now
            if (!(buf[0] >> 7)) c.flags |= J40__NO_MORE_CODESTREAM_BOX;
            if (size < INT64_MAX) size -= 4;
            break;

        case 0x62726f62: // brob: brotli-compressed box
            
            // Brotli stream is never empty so 4 is also out
            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((size > 4) == 0)) 
            { 
                j40__set_error(st, J40__4("brot")); 
                goto J40__ON_ERROR; 
            }

            if (J40_UNLIKELY(j40__read_from_source(st, buf.ptr, 4))) 
            { 
                assert(st.err); 
                goto J40__ON_ERROR; 
            }

            type = j40__u32be(buf.ptr);

            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((type != 0x62726f62 /*brob*/ && (type >> 8) != 0x6a786c /*jxl*/) == 0)) 
            { 
                j40__set_error(st, J40__4("brot")); 
                goto J40__ON_ERROR; 
            }

            if (size < INT64_MAX) size -= 4;
            break;
        default:
            break;
        } // other boxes have no additional requirements and are simply skipped

        // this box has an indeterminate size and thus there is no more box following
        if (size == INT64_MAX) {
            if (codestream_box) c.flags |= J40__IMPLIED_LAST_MAP_ENTRY;
            c.flags |= J40__NO_MORE_BOX;
            break;
        }

        if (codestream_box) {
            // add a new entry. at this point C[nmap-1] is the first codestream offset in this box
            // and F[nmap-1] points to the beginning of this box, which should be updated to
            // the beginning of the box *contents*.
            j40__map *newptr = cast(j40__map*) j40__realloc32(st, *(&c.map), 
                                                              j40__map.sizeof, c.nmap + 1, &c.map_cap);
            if (J40_LIKELY(newptr != null)) 
                *(&c.map) = newptr; 
            else 
                goto J40__ON_ERROR;
            
            c.map[c.nmap - 1].fileoff = source.fileoff;
            
            if (J40_UNLIKELY((j40__add64(c.map[c.nmap - 1].codeoff, size, &c.map[c.nmap].codeoff)) == 0)) 
            { 
                j40__set_error(st, J40__4("flen")); 
                goto J40__ON_ERROR; 
            }

            // F[nmap] gets updated in the common case.
            if (J40_UNLIKELY((j40__add32(c.nmap, 1, &c.nmap)) == 0)) 
            { 
                j40__set_error(st, J40__4("flen")); 
                goto J40__ON_ERROR; 
            }
        }

        // always maintains F[nmap-1] to be the beginning of the next box (and seek to that point).
        // we've already read the previous box header, so this should happen even if seek fails.
        if (J40_UNLIKELY((j40__add64(source.fileoff, size, &c.map[c.nmap - 1].fileoff)) == 0)) 
        { 
            j40__set_error(st, J40__4("flen")); 
            goto J40__ON_ERROR; 
        }

        if (J40_UNLIKELY(j40__seek_from_source(st, c.map[c.nmap - 1].fileoff))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        }
    }

    // now the EOF has been reached or the last box had an indeterminate size.
    // EOF condition can be recovered (i.e. we can add more boxes to get it correctly decoded)
    // so it's not a hard error, but we can't recover from an indeterminately sized box.
    if ((c.flags & J40__NO_MORE_BOX) && !(c.flags & (J40__SEEN_JXLC | J40__SEEN_JXLP))) {
        st.cannot_retry = 1;
        j40__set_error(st, J40__4("shrt")); 
        goto J40__ON_ERROR;
    }

J40__ON_ERROR:
    return st.err;
}

// returns i such that codeoff is in [C[i], C[i+1]), or nmap-1 if there is no such map entry
int j40__search_codestream_offset(const j40__st *st, long codeoff) 
{
    const(j40__map)* map = st.container.map;
    int nmap = st.container.nmap, i;
    assert(map && nmap > 0);
    // TODO use a binary search instead
    for (i = 1; i < nmap; ++i) {
        if (codeoff < map[i].codeoff) break;
    }
    return i - 1;
}

j40_err j40__map_codestream_offset(j40__st *st, long codeoff, long *fileoff) {
    j40__map *map = st.container.map;
    int nmap = st.container.nmap, i;

    i = j40__search_codestream_offset(st, codeoff);
    if (i < nmap - 1) {
        assert(codeoff - map[i].codeoff < map[i+1].fileoff - map[i].fileoff);
        *fileoff = map[i].fileoff + (codeoff - map[i].codeoff); // thus this never overflows
    } else if (st.container.flags & J40__IMPLIED_LAST_MAP_ENTRY) 
    {
        if (J40_UNLIKELY(st.err)) 
            goto J40__ON_ERROR;
        if (J40_UNLIKELY((j40__add64(map[nmap-1].fileoff, codeoff - map[nmap-1].codeoff, fileoff)) == 0)) 
        { 
            j40__set_error(st, J40__4("flen")); 
            goto J40__ON_ERROR; 
        }
    } 
    else if (st.container.flags & J40__NO_MORE_CODESTREAM_BOX) 
    {
        // TODO is this valid to do? j40__end_of_frame depends on this.
        if (codeoff == map[nmap-1].codeoff) {
            *fileoff = map[nmap-1].fileoff;
        } else {
            st.cannot_retry = 1;
            j40__set_error(st, J40__4("shrt")); 
            goto J40__ON_ERROR;
        }
    } else {
        j40__set_error(st, J40__4("shrt")); 
        goto J40__ON_ERROR;
    }

J40__ON_ERROR:
    return st.err;
}

void j40__free_container(j40__container_st *container) 
{
    j40__free(container.map);
    container.map = null;
    container.nmap = container.map_cap = 0;
}

////////////////////////////////////////////////////////////////////////////////
// backing buffer

struct j40__buffer_st  // zero-initialized
{
    ubyte *buf = null;
    long size = 0, 
         capacity = 0;

    long next_codeoff = 0; // the codestream offset right past the backing buffer (i.e. `buf[size]`)
    long codeoff_limit = 0; // codestream offset can't exceed this; used for per-section decoding

    j40__bits_st checkpoint; // the earliest point that the parser can ever backtrack
}


enum J40__INITIAL_BUFSIZE = 0x10000;

j40_err j40__init_buffer(j40__st *st, long codeoff, long codeoff_limit) 
{
    j40__bits_st* bits = &st.bits, 
                  checkpoint = &st.buffer.checkpoint;
    j40__buffer_st* buffer = st.buffer;

    assert(!buffer.buf);

    ubyte *newptr = cast(ubyte*) j40__malloc(J40__INITIAL_BUFSIZE, ubyte.sizeof);

    if (J40_UNLIKELY(st.err)) 
        goto J40__ON_ERROR;
    if (J40_UNLIKELY((*(&buffer.buf) = newptr) == null)) 
    { 
        j40__set_error(st, J40__4("!mem")); 
        goto J40__ON_ERROR; 
    }

    bits.ptr = bits.end = buffer.buf;
    buffer.size = 0;
    buffer.capacity = J40__INITIAL_BUFSIZE;
    buffer.next_codeoff = codeoff;
    buffer.codeoff_limit = codeoff_limit;
    bits.bits = 0;
    bits.nbits = 0;
    *checkpoint = *bits;
J40__ON_ERROR:
    return st.err;
}

j40_err j40__refill(j40__st *st, int n)
{
    return J40_UNLIKELY(st.bits.nbits < (n)) ? j40__always_refill(st, n) : st.err;
}

j40_err j40__refill_buffer(j40__st *st) 
{
    j40__bits_st* bits = &st.bits, 
                  checkpoint = &st.buffer.checkpoint;
    j40__buffer_st *buffer = st.buffer;
    j40__container_st *container = st.container;
    long available, wanted_codeoff;
    int i;

    assert(J40__INBOUNDS(bits.ptr, buffer.buf, cast(size_t) buffer.size));
    assert(J40__INBOUNDS(checkpoint.ptr, buffer.buf, cast(size_t) buffer.size));
    assert(checkpoint.ptr <= bits.ptr);

    // trim the committed portion from the backing buffer
    if (checkpoint.ptr > buffer.buf) {
        long committed_size = cast(long) (checkpoint.ptr - buffer.buf);
        assert(committed_size <= buffer.size); // so committed_size can't overflow
        // this also can't overflow, because buffer.size never exceeds SIZE_MAX
        memmove(buffer.buf, checkpoint.ptr, cast(size_t) (buffer.size - committed_size));
        buffer.size -= committed_size;
        bits.ptr -= committed_size;
        bits.end -= committed_size;
        checkpoint.ptr = buffer.buf;
    }

    // if there is no room left in the backing buffer, it's time to grow it
    if (buffer.size == buffer.capacity) 
    {
        long newcap = j40__clamp_add64(buffer.capacity, buffer.capacity);
        ptrdiff_t relptr = bits.ptr - buffer.buf;

        ubyte *newptr = cast(ubyte*) j40__realloc64(st, *(&buffer.buf), ubyte.sizeof, newcap, &buffer.capacity);
        if (J40_LIKELY(newptr != null)) 
            *(&buffer.buf) = newptr; 
        else 
            goto J40__ON_ERROR;
        bits.ptr = buffer.buf + relptr;
        checkpoint.ptr = buffer.buf;
    }

    wanted_codeoff = j40__min64(buffer.codeoff_limit,
        j40__clamp_add64(buffer.next_codeoff, buffer.capacity - buffer.size));
    available = wanted_codeoff - buffer.next_codeoff;
    --wanted_codeoff; // ensure that this is inclusive, i.e. the last byte offset *allowed*

    // do the initial mapping if no map is available
    if (!container.map) 
    {
        if (J40_UNLIKELY(j40__container(st, wanted_codeoff))) { assert(st.err); goto J40__ON_ERROR; }
    }

    i = j40__search_codestream_offset(st, buffer.next_codeoff);
    while (available > 0) {
        j40__map *map = container.map;
        int nmap = container.nmap;
        long fileoff, readable_size, read_size;

        if (i < nmap - 1) {
            long box_size = map[i+1].codeoff - map[i].codeoff;
            assert(box_size > 0);
            readable_size = j40__min64(available, map[i+1].codeoff - buffer.next_codeoff);
            assert(buffer.next_codeoff - map[i].codeoff < map[i+1].fileoff - map[i].fileoff);
            fileoff = map[i].fileoff + (buffer.next_codeoff - map[i].codeoff); // thus can't overflow
        } 
        else if (container.flags & J40__IMPLIED_LAST_MAP_ENTRY) 
        {
            readable_size = available;
            if (J40_UNLIKELY(st.err)) 
                goto J40__ON_ERROR;
            if (J40_UNLIKELY((j40__add64(map[i].fileoff, buffer.next_codeoff - map[nmap-1].codeoff, &fileoff)) == 0)) 
            { 
                j40__set_error(st, J40__4("flen")); 
                goto J40__ON_ERROR; 
            }

        } else {
            
            do { if (J40_UNLIKELY(j40__container(st, wanted_codeoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            if (nmap == container.nmap && !(container.flags & J40__IMPLIED_LAST_MAP_ENTRY)) {
                break; 
            }
            continue;
        }
        assert(readable_size > 0);

        do { if (J40_UNLIKELY(j40__seek_from_source(st, fileoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__try_read_from_source(st, buffer.buf + buffer.size, 0, readable_size, &read_size))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        if (read_size == 0) break; 

        buffer.size += read_size;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__add64(buffer.next_codeoff, read_size, &buffer.next_codeoff)) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);
        bits.end = checkpoint.end = buffer.buf + buffer.size;
        available -= read_size;
        if (read_size == readable_size) ++i; 
    }

J40__ON_ERROR:
    return st.err;
}

j40_err j40__seek_buffer(j40__st *st, long codeoff) {
    long reusable_size = st.buffer.next_codeoff - codeoff, fileoff;
    st.bits.bits = 0;
    st.bits.nbits = 0;
    if (0 < reusable_size && reusable_size <= st.buffer.size) {
        st.bits.ptr = st.buffer.buf + (st.buffer.size - reusable_size);
        st.bits.end = st.buffer.buf + st.buffer.size;
    } else {
        st.bits.ptr = st.bits.end = st.buffer.buf;
        st.buffer.size = 0;
        st.buffer.next_codeoff = codeoff;
        do { if (J40_UNLIKELY(j40__map_codestream_offset(st, codeoff, &fileoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__seek_from_source(st, fileoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
J40__ON_ERROR:
    return st.err;
}

long j40__codestream_offset(const j40__st* st) 
{
    assert(st.bits.nbits % 8 == 0);
    return st.buffer.next_codeoff - st.buffer.size + (st.bits.ptr - st.buffer.buf) - st.bits.nbits / 8;
}


long j40__bits_read(const j40__st *st) 
{
    int nbytes = j40__ceil_div32(st.bits.nbits, 8), nbits = 8 * nbytes - st.bits.nbits;
    
    long codeoff = st.buffer.next_codeoff - st.buffer.size + (st.bits.ptr - st.buffer.buf) - nbytes;
    j40__map map = st.container.map[j40__search_codestream_offset(st, codeoff)];
    return (map.fileoff + (codeoff - map.codeoff)) * 8 + nbits;
}

void j40__free_buffer(j40__buffer_st *buffer) 
{
    j40__free(buffer.buf);
    buffer.buf = null;
    buffer.size = buffer.capacity = 0;
}








j40_err j40__always_refill(j40__st *st, int n) 
{
    enum int NBITS = 64;
    j40__bits_st *bits = &st.bits;

    assert(0 <= n && n < NBITS);
    while (1) 
    {
        int consumed = (NBITS - bits.nbits) >> 3;
        if (J40_LIKELY(bits.end - bits.ptr >= consumed))
        {
            
            assert(bits.nbits <= NBITS - 8);
            do {
                bits.bits |= cast(ulong) *bits.ptr++ << bits.nbits;
                bits.nbits += 8;
            } while (bits.nbits <= NBITS - 8);
            break;
        }

        
        while (bits.ptr < bits.end) 
        {
            bits.bits |= cast(ulong) *bits.ptr++ << bits.nbits;
            bits.nbits += 8;
        }
        if (bits.nbits > NBITS - 8) break;

        if (!(st.buffer))
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((st.buffer) == null)) { j40__set_error(st, J40__4("shrt")); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__refill_buffer(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        if (bits.end == bits.ptr) { 
            if (bits.nbits >= n) break;
            do { j40__set_error(st, J40__4("shrt")); goto J40__ON_ERROR; } while (0);
        }
        
    }

J40__ON_ERROR:
    return st.err;
}

j40_err j40__zero_pad_to_byte(j40__st *st) 
{
    int n = st.bits.nbits & 7;
    if (st.bits.bits & ((1u << n) - 1)) 
        return j40__set_error(st, J40__4("pad0"));
    st.bits.bits >>= n;
    st.bits.nbits -= n;
    return st.err;
}

j40_err j40__skip(j40__st *st, long n) 
{
    j40__bits_st *bits = &st.bits;
    long bytes;
    if (bits.nbits >= n) {
        bits.bits >>= cast(int) n;
        bits.nbits -= cast(int) n;
    } else {
        n -= bits.nbits;
        bits.bits = 0;
        bits.nbits = 0;
    }
    bytes = n >> 3;
    
    if (bits.end - bits.ptr < cast(long) bytes) return j40__set_error(st, J40__4("shrt"));
    bits.ptr += bytes;
    n &= 7;
    if (j40__refill(st, cast(int) n)) return st.err;
    bits.bits >>= cast(int) n;
    bits.nbits -= cast(int) n;
    return st.err;
}

int j40__u(j40__st *st, int n) 
{
    int ret;
    assert(0 <= n && n <= 31);
    if (j40__refill(st, n)) return 0;
    ret = cast(int) (st.bits.bits & ((1u << n) - 1));
    st.bits.bits >>= n;
    st.bits.nbits -= n;
    return ret;
}

long j40__64u(j40__st *st, int n) 
{
    long ret;
    assert(0 <= n && n <= 63);
    if (j40__refill(st, n)) return 0;
    ret = cast(long) (st.bits.bits & ((cast(ulong) 1u << n) - 1));
    st.bits.bits >>= n;
    st.bits.nbits -= n;
    return ret;
}

int j40__u32(
    j40__st *st,
    int o0, int n0, int o1, int n1,
    int o2, int n2, int o3, int n3
) {
    const int[4] o = [ o0, o1, o2, o3 ];
    const int[4] n = [ n0, n1, n2, n3 ];
    int sel;
    assert(0 <= n0 && n0 <= 30 && o0 <= 0x7fffffff - (1 << n0));
    assert(0 <= n1 && n1 <= 30 && o1 <= 0x7fffffff - (1 << n1));
    assert(0 <= n2 && n2 <= 30 && o2 <= 0x7fffffff - (1 << n2));
    assert(0 <= n3 && n3 <= 30 && o3 <= 0x7fffffff - (1 << n3));
    sel = j40__u(st, 2);
    return j40__u(st, n[sel]) + o[sel];
}

long j40__64u32(
    j40__st *st,
    int o0, int n0, int o1, int n1,
    int o2, int n2, int o3, int n3
) {
    const int[4] o = [ o0, o1, o2, o3 ];
    const int[4] n = [ n0, n1, n2, n3 ];
    int sel;
    assert(0 <= n0 && n0 <= 62);
    assert(0 <= n1 && n1 <= 62);
    assert(0 <= n2 && n2 <= 62);
    assert(0 <= n3 && n3 <= 62);
    sel = j40__u(st, 2);
    return (j40__64u(st, n[sel]) + cast(long) o[sel]) & cast(long) 0xffffffff;
}

ulong j40__u64(j40__st *st) {
    int sel = j40__u(st, 2), shift;
    ulong ret = cast(ulong) j40__u(st, sel * 4);
    if (sel < 3) {
        ret += 17u >> (8 - sel * 4);
    } else {
        for (shift = 12; shift < 64 && j40__u(st, 1); shift += 8) {
            ret |= cast(ulong) j40__u(st, shift < 56 ? 8 : 64 - shift) << shift;
        }
    }
    return ret;
}

int j40__enum(j40__st *st) 
{
    int ret = j40__u32(st, 0, 0, 1, 0, 2, 4, 18, 6);
    // the spec says it should be 64, but the largest enum value in use is 18 (kHLG);
    // we have to reject unknown enum values anyway so we use a smaller limit to avoid overflow
    if (ret >= 31)
    {
        j40__set_error(st, J40__4("enum"));
        return 0;
    }
    return ret;
}

float j40__f16(j40__st *st) {
    int bits = j40__u(st, 16);
    int biased_exp = (bits >> 10) & 0x1f;
    if (biased_exp == 31) 
    {
        j40__set_error(st, J40__4("!fin"));
        return 0.0f;
    }
    return (bits >> 15 ? -1 : 1) * ldexpf(cast(float) ((bits & 0x3ff) | (biased_exp > 0 ? 0x400 : 0)), biased_exp - 25);
}

int j40__u8(j40__st *st) { // ANS distribution decoding only
    if (j40__u(st, 1)) {
        int n = j40__u(st, 3);
        return j40__u(st, n) + (1 << n);
    } else {
        return 0;
    }
}

// equivalent to u(ceil(log2(max + 1))), decodes [0, max] with the minimal number of bits
int j40__at_most(j40__st *st, int max) 
{
    int v = max > 0 ? j40__u(st, j40__ceil_lg32(cast(uint) max + 1)) : 0;
    if (v > max)
    {
        j40__set_error(st, J40__4("rnge"));
        return 0;
    }
    return v;
}

// ensures that we have reached the end of file or advertised section with proper padding
j40_err j40__no_more_bytes(j40__st *st) {
    do { if (J40_UNLIKELY(j40__zero_pad_to_byte(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((st.bits.nbits == 0 && st.bits.ptr == st.bits.end) == 0)) { j40__set_error(st, J40__4("excs")); goto J40__ON_ERROR; } } while (0);
J40__ON_ERROR:
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// prefix code

// a prefix code tree is represented by max_len (max code length), fast_len (explained below),
// and an int table either statically or dynamically constructed.
// table[0] .. table[(1 << fast_len) - 1] are a lookup table for first fast_len bits.
// each entry is either a direct entry (positive),
// or an index to the first overflow entry (negative, the actual index is -table[i]).
//
// subsequent overflow entries are used for codes with the length > fast_len;
// the decoder reads overflow entries in the order, stopping at the first match.
// the last overflow entry is implicit so the table is constructed to ensure the match.
//
// a direct or overflow entry format:
// - bits 0..3: codeword length - fast_len
// - bits 4..15: codeword, skipping first fast_len bits, ordered like st.bits.bits (overflow only)
// - bits 16..30: corresponding alphabet

enum { J40__MAX_TYPICAL_FAST_LEN = 7 }; // limit fast_len for typical cases
enum { J40__MAX_TABLE_GROWTH = 2 }; // we can afford 2x the table size if beneficial though

// read a prefix code tree, as specified in RFC 7932 section 3
j40_err j40__prefix_code_tree(
    j40__st *st, int l2size, int *out_fast_len, int *out_max_len, int **out_table
) {
    static immutable ubyte[32] REV5 = [
        0, 16, 8, 24, 4, 20, 12, 28, 2, 18, 10, 26, 6, 22, 14, 30,
        1, 17, 9, 25, 5, 21, 13, 29, 3, 19, 11, 27, 7, 23, 15, 31,
    ];

    // for ordinary cases we have three different prefix codes:
    // layer 0 (fixed): up to 4 bits, decoding into 0..5, used L1SIZE = 18 times
    // layer 1: up to 5 bits, decoding into 0..17, used l2size times
    // layer 2: up to 15 bits, decoding into 0..l2size-1
    enum { L1SIZE = 18, L0MAXLEN = 4, L1MAXLEN = 5, L2MAXLEN = 15 }
    enum { L1CODESUM = 1 << L1MAXLEN, L2CODESUM = 1 << L2MAXLEN }
    static immutable int[1 << L0MAXLEN] L0TABLE = [
        0x00002, 0x40002, 0x30002, 0x20003, 0x00002, 0x40002, 0x30002, 0x10004,
        0x00002, 0x40002, 0x30002, 0x20003, 0x00002, 0x40002, 0x30002, 0x50004,
    ];
    static immutable ubyte[L1SIZE] L1ZIGZAG = [1,2,3,4,0,5,17,6,16,7,8,9,10,11,12,13,14,15];

    int[L1SIZE] l1lengths = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]; 

    int* l2lengths = null;
    int[L1MAXLEN + 1] l1counts = [0,0,0,0,0,0];
    int[L2MAXLEN + 1] l2counts = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];

    int[L1MAXLEN + 1] l1starts;
    int[L2MAXLEN + 1] l2starts;
    int[L2MAXLEN + 1] l2overflows;

    int[1 << L1MAXLEN] l1table;
    l1table[] = 0;
    int* l2table = null;
    int total, code, hskip, fast_len, i, j;

    assert(l2size > 0 && l2size <= 0x8000);
    if (l2size == 1) 
    { 
        // SPEC missing this case
        *out_fast_len = *out_max_len = 0;

        int *newptr = cast(int*) j40__malloc(1, int.sizeof);
        *(out_table) = newptr;

        (*out_table)[0] = 0;
        return 0;
    }

    static struct PrefixCode
    { 
        byte maxlen, sortfrom, sortto;
        byte[8] len;
        byte[8] symref;
    }

    hskip = j40__u(st, 2);
    if (hskip == 1) 
    { // simple prefix codes (section 3.4)
        static immutable PrefixCode[5] TEMPLATES = 
        [
            PrefixCode( 3, 2, 4, [1,2,1,3,1,2,1,3], [0,1,0,2,0,1,0,3] ), // NSYM=4 tree-select 1 (1233)
            PrefixCode( 0, 0, 0, [0,0,0,0,0,0,0,0], [0,0,0,0,0,0,0,0] ),                             // NSYM=1 (0)
            PrefixCode( 1, 0, 2, [1,1,0,0,0,0,0,0], [0,1,0,0,0,0,0,0] ),                         // NSYM=2 (11)
            PrefixCode( 2, 1, 3, [1,2,1,2,0,0,0,0], [0,1,0,2,0,0,0,0] ),                 // NSYM=3 (122)
            PrefixCode( 2, 0, 4, [2,2,2,2,0,0,0,0], [0,1,2,3,0,0,0,0] ),                 // NSYM=4 tree-select 0 (2222)
        ];

        int nsym = j40__u(st, 2) + 1;
        int[4] syms;
        int tmp;
        for (i = 0; i < nsym; ++i) {
            syms[i] = j40__at_most(st, l2size - 1);
            for (j = 0; j < i; ++j) do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((syms[i] != syms[j]) == 0)) { j40__set_error(st, J40__4("hufd")); goto J40__ON_ERROR; } } while (0);
        }
        if (nsym == 4 && j40__u(st, 1)) nsym = 0; // tree-select
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);

        // symbols of the equal length have to be sorted
        for (i = TEMPLATES[nsym].sortfrom + 1; i < TEMPLATES[nsym].sortto; ++i) {
            for (j = i; j > TEMPLATES[nsym].sortfrom && syms[j - 1] > syms[j]; --j) {
                tmp = syms[j - 1];
                syms[j - 1] = syms[j];
                syms[j] = tmp;
            }
        }

        *out_fast_len = *out_max_len = TEMPLATES[nsym].maxlen;

        int *newptr = cast(int*) j40__malloc(1u << *out_max_len, int.sizeof);
        *(out_table) = newptr;


        for (i = 0; i < (1 << *out_max_len); ++i) {
            (*out_table)[i] = (syms[TEMPLATES[nsym].symref[i]] << 16) | cast(int) TEMPLATES[nsym].len[i];
        }
        return 0;
    }

    // complex prefix codes (section 3.5): read layer 1 code lengths using the layer 0 code
    total = 0;
    for (i = l1counts[0] = hskip; i < L1SIZE && total < L1CODESUM; ++i) 
    {
        l1lengths[L1ZIGZAG[i]] = code = j40__prefix_code(st, L0MAXLEN, L0MAXLEN, L0TABLE.ptr);
        ++l1counts[code];
        if (code) total += L1CODESUM >> code;
    }
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((total == L1CODESUM && l1counts[0] != i) == 0)) { j40__set_error(st, J40__4("hufd")); goto J40__ON_ERROR; } } while (0);

    // construct the layer 1 tree
    if (l1counts[0] == i - 1) { // special case: a single code repeats as many as possible
        for (i = 0; l1lengths[i]; ++i){} // this SHOULD terminate
        for (code = 0; code < L1CODESUM; ++code) l1table[code] = i;
        l1lengths[i] = 0;
    } else {
        l1starts[1] = 0;
        for (i = 2; i <= L1MAXLEN; ++i) {
            l1starts[i] = l1starts[i - 1] + (l1counts[i - 1] << (L1MAXLEN - (i - 1)));
        }
        for (i = 0; i < L1SIZE; ++i) {
            int n = l1lengths[i];
            int* start = &l1starts[n];
            if (n == 0) continue;
            for (code = cast(int) REV5[*start]; code < L1CODESUM; code += 1 << n) {
                l1table[code] = (i << 16) | n;
            }
            *start += L1CODESUM >> n;
        }
    }

    { // read layer 2 code lengths using the layer 1 code
        int prev = 8, rep, prev_rep = 0; // prev_rep: prev repeat count of 16(pos)/17(neg) so far
        
        int *newptr = cast(int*) j40__calloc(cast(size_t) l2size, int.sizeof);
        *(&l2lengths) = newptr;

        for (i = total = 0; i < l2size && total < L2CODESUM; ) {
            code = j40__prefix_code(st, L1MAXLEN, L1MAXLEN, l1table.ptr);
            if (code < 16) {
                l2lengths[i++] = code;
                ++l2counts[code];
                if (code) {
                    total += L2CODESUM >> code;
                    prev = code;
                }
                prev_rep = 0;
            } else if (code == 16) { // repeat non-zero 3+u(2) times
                // instead of keeping the current repeat count, we calculate a difference
                // between the previous and current repeat count and directly apply the delta
                if (prev_rep < 0) prev_rep = 0;
                rep = (prev_rep > 0 ? 4 * prev_rep - 5 : 3) + j40__u(st, 2);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((i + (rep - prev_rep) <= l2size) == 0)) { j40__set_error(st, J40__4("hufd")); goto J40__ON_ERROR; } } while (0);
                total += (L2CODESUM * (rep - prev_rep)) >> prev;
                l2counts[prev] += rep - prev_rep;
                for (; prev_rep < rep; ++prev_rep) l2lengths[i++] = prev;
            } else { // code == 17: repeat zero 3+u(3) times
                if (prev_rep > 0) prev_rep = 0;
                rep = (prev_rep < 0 ? 8 * prev_rep + 13 : -3) - j40__u(st, 3);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((i + (prev_rep - rep) <= l2size) == 0)) { j40__set_error(st, J40__4("hufd")); goto J40__ON_ERROR; } } while (0);
                for (; prev_rep > rep; --prev_rep) l2lengths[i++] = 0;
            }
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
        }
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((total == L2CODESUM) == 0)) { j40__set_error(st, J40__4("hufd")); goto J40__ON_ERROR; } } while (0);
    }

    // determine the layer 2 lookup table size
    l2starts[1] = 0;
    *out_max_len = 1;
    for (i = 2; i <= L2MAXLEN; ++i) {
        l2starts[i] = l2starts[i - 1] + (l2counts[i - 1] << (L2MAXLEN - (i - 1)));
        if (l2counts[i]) *out_max_len = i;
    }
    if (*out_max_len <= J40__MAX_TYPICAL_FAST_LEN) 
    {
        fast_len = *out_max_len;
        int *newptr = cast(int*) j40__malloc(1u << fast_len, int.sizeof);
        *(&l2table) = newptr;
    } else {
        // if the distribution is flat enough the max fast_len might be slow
        // because most LUT entries will be overflow refs so we will hit slow paths for most cases.
        // we therefore calculate the table size with the max fast_len,
        // then find the largest fast_len within the specified table growth factor.
        int size, size_limit, size_used;
        fast_len = J40__MAX_TYPICAL_FAST_LEN;
        size = 1 << fast_len;
        for (i = fast_len + 1; i <= *out_max_len; ++i) size += l2counts[i];
        size_used = size;
        size_limit = size * J40__MAX_TABLE_GROWTH;
        for (i = fast_len + 1; i <= *out_max_len; ++i) {
            size = size + (1 << i) - l2counts[i];
            if (size <= size_limit) {
                size_used = size;
                fast_len = i;
            }
        }
        l2overflows[fast_len + 1] = 1 << fast_len;
        for (i = fast_len + 2; i <= *out_max_len; ++i) 
            l2overflows[i] = l2overflows[i - 1] + l2counts[i - 1];

        int *newptr = cast(int*) j40__malloc(cast(size_t) (size_used + 1), int.sizeof);
        *(&l2table) = newptr;

        // this entry should be unreachable, but should work as a stopper if there happens to be a logic bug
        l2table[size_used] = 0;
    }

    // fill the layer 2 table
    for (i = 0; i < l2size; ++i) {
        int n = l2lengths[i];
        int *start = &l2starts[n];
        if (n == 0) continue;
        code = (cast(int) REV5[*start & 31] << 10) |
            (cast(int) REV5[*start >> 5 & 31] << 5) |
            (cast(int) REV5[*start >> 10]);
        if (n <= fast_len) {
            for (; code < (1 << fast_len); code += 1 << n) l2table[code] = (i << 16) | n;
            *start += L2CODESUM >> n;
        } else {
            // there should be exactly one code which is a LUT-covered prefix plus all zeroes;
            // in the canonical Huffman tree that code would be in the first overflow entry
            if ((code >> fast_len) == 0) l2table[code] = -l2overflows[n];
            *start += L2CODESUM >> n;
            l2table[l2overflows[n]++] = (i << 16) | (code >> fast_len << 4) | (n - fast_len);
        }
    }

    *out_fast_len = fast_len;
    *out_table = l2table;
    j40__free(l2lengths);
    return 0;

J40__ON_ERROR:
    j40__free(l2lengths);
    j40__free(l2table);
    return st.err;
}

int j40__match_overflow(j40__st *st, int fast_len, const(int)* table) 
{
    int entry, code, code_len;
    st.bits.nbits -= fast_len;
    st.bits.bits >>= fast_len;
    do {
        entry = *table++;
        code = (entry >> 4) & 0xfff;
        code_len = entry & 15;
    } while (code != cast(int) (st.bits.bits & ((1u << code_len) - 1)));
    return entry;
}

int j40__prefix_code(j40__st *st, int fast_len, int max_len, const int *table) {
    int entry, code_len;
    // this is not `j40__refill(st, max_len)` because it should be able to handle codes
    // at the very end of file or section and shorter than max_len bits; in that case
    // the bit buffer will correctly contain a short code padded with zeroes.
    if (st.bits.nbits < max_len && j40__always_refill(st, 0)) return 0;
    entry = table[st.bits.bits & ((1u << fast_len) - 1)];
    if (entry < 0 && fast_len < max_len) entry = j40__match_overflow(st, fast_len, table - entry);
    code_len = entry & 15;
    st.bits.nbits -= code_len;
    st.bits.bits >>= code_len;
    if (st.bits.nbits < 0) { // too many bits read from the bit buffer
        st.bits.nbits = 0;
        assert(st.bits.bits == 0);
        j40__set_error(st, J40__4("shrt"));
    }
    return entry >> 16;
}

////////////////////////////////////////////////////////////////////////////////
// hybrid integer encoding

// token < 2^split_exp is interpreted as is.
// otherwise (token - 2^split_exp) is split into NNHHHLLL where config determines H/L lengths.
// then MMMMM = u(NN + split_exp - H/L lengths) is read; the decoded value is 1HHHMMMMMLLL.
struct j40__hybrid_int_config
{
    byte split_exp = 0; // [0, 15]
    byte msb_in_token = 0, 
         lsb_in_token = 0; // msb_in_token + lsb_in_token <= split_exp
    // TODO 2^30 bound is arbitrary, codestream may require larger values for some edge cases
    int max_token = 0; // upper bound of token s.t. `j40__hybrid_int(token)` is < 2^30
}

j40_err j40__read_hybrid_int_config(
    j40__st *st, int log_alpha_size, j40__hybrid_int_config *out_
) 
{
    assert(log_alpha_size <= 15);
    out_.split_exp = cast(byte) j40__at_most(st, log_alpha_size);
    if (out_.split_exp != log_alpha_size) {
        out_.msb_in_token = cast(byte) j40__at_most(st, out_.split_exp);
        out_.lsb_in_token = cast(byte) j40__at_most(st, out_.split_exp - out_.msb_in_token);
    } else {
        out_.msb_in_token = out_.lsb_in_token = 0;
    }
    out_.max_token =
        (1 << out_.split_exp) + ((30 - out_.split_exp) << (out_.lsb_in_token + out_.msb_in_token)) - 1;
    return st.err;
}

int j40__hybrid_int(j40__st *st, int token, j40__hybrid_int_config config) {
    int midbits, lo, mid, hi, top, bits_in_token, split = 1 << config.split_exp;
    if (token < split) return token;
    if (token > config.max_token) {
        token = config.max_token;
        j40__set_error(st, J40__4("iovf"));
    }
    bits_in_token = config.msb_in_token + config.lsb_in_token;
    midbits = config.split_exp - bits_in_token + ((token - split) >> bits_in_token);
    mid = j40__u(st, midbits);
    top = 1 << config.msb_in_token;
    lo = token & ((1 << config.lsb_in_token) - 1);
    hi = (token >> config.lsb_in_token) & (top - 1);
    return ((top | hi) << (midbits + config.lsb_in_token)) | ((mid << config.lsb_in_token) | lo);
}

////////////////////////////////////////////////////////////////////////////////
// rANS alias table

enum : int
{
    J40__DIST_BITS = 12,
    J40__ANS_INIT_STATE = 0x130000
}

// the alias table of size N is conceptually an array of N buckets with probability 1/N each,
// where each bucket corresponds to at most two symbols distinguished by the cutoff point.
// this is done by rearranging symbols so that every symbol boundary falls into distinct buckets.
// so it allows *any* distribution of N symbols to be decoded in a constant time after the setup.
// the table is not unique though, so the spec needs to specify the exact construction algorithm.
//
//   input range: 0         cutoff               bucket_size
//                +-----------|----------------------------+
// output symbol: |     i     |           symbol           | <- bucket i
//                +-----------|----------------------------+
//  output range: 0     cutoff|offset    offset+bucket_size
struct j40__alias_bucket
{ 
    short cutoff, offset_or_next, symbol;
}

j40_err j40__init_alias_map(
    j40__st *st, const short *D, int log_alpha_size, j40__alias_bucket **out_
) {
    short log_bucket_size = cast(short) (J40__DIST_BITS - log_alpha_size);
    short bucket_size = cast(short) (1 << log_bucket_size);
    short table_size = cast(short) (1 << log_alpha_size);
    j40__alias_bucket *buckets = null;
    // the underfull and overfull stacks are implicit linked lists; u/o resp. is the top index,
    // buckets[u/o].next is the second-to-top index and so on. an index -1 indicates the bottom.
    short u = -1, o = -1, i, j;

    assert(5 <= log_alpha_size && log_alpha_size <= 8);

    j40__alias_bucket *newptr = cast(j40__alias_bucket*) j40__malloc(1u << log_alpha_size, j40__alias_bucket.sizeof);
    *(&buckets) = newptr;

    for (i = 0; i < table_size && !D[i]; ++i){}
    for (j = cast(short) (i + 1); j < table_size && !D[j]; ++j){}
    if (i < table_size && j >= table_size) { // D[i] is the only non-zero probability
        for (j = 0; j < table_size; ++j) {
            buckets[j].symbol = i;
            buckets[j].offset_or_next /*offset*/ = cast(short) (j << log_bucket_size);
            buckets[j].cutoff = 0;
        }
        *out_ = buckets;
        return 0;
    }

    // each bucket is either settled (fields fully set) or unsettled (only `cutoff` is set).
    // unsettled buckets are either in the underfull stack, in which case `cutoff < bucket_size`,
    // or in the overfull stack, in which case `cutoff > bucket_size`. other fields are left
    // unused, so `offset` in settled buckets is aliased to `next` in unsettled buckets.
    // when rearranging results in buckets with `cutoff == bucket_size`,
    // final fields are set and they become settled; eventually every bucket has to be settled.
    for (i = 0; i < table_size; ++i) {
        short cutoff = D[i];
        buckets[i].cutoff = cutoff;
        if (cutoff > bucket_size) {
            buckets[i].offset_or_next /*next*/ = o;
            o = i;
        } else if (cutoff < bucket_size) {
            buckets[i].offset_or_next /*next*/ = u;
            u = i;
        } else { // immediately settled
            buckets[i].symbol = i;
            buckets[i].offset_or_next /*offset*/ = 0;
        }
    }

    while (o >= 0) {
        short by, tmp;
        assert(u >= 0);
        by = cast(short) (bucket_size - buckets[u].cutoff);
        // move the input range [cutoff[o] - by, cutoff[o]] of the bucket o into
        // the input range [cutoff[u], bucket_size] of the bucket u (which is settled after this)
        tmp = buckets[u].offset_or_next /*next*/;
        buckets[o].cutoff = cast(short) (buckets[o].cutoff - by);
        buckets[u].symbol = o;
        buckets[u].offset_or_next /*offset*/ = cast(short) (buckets[o].cutoff - buckets[u].cutoff);
        u = tmp;
        if (buckets[o].cutoff < bucket_size) { // o is now underfull, move to the underfull stack
            tmp = buckets[o].offset_or_next /*next*/;
            buckets[o].offset_or_next /*next*/ = u;
            u = o;
            o = tmp;
        } else if (buckets[o].cutoff == bucket_size) { // o is also settled
            tmp = buckets[o].offset_or_next /*next*/;
            buckets[o].offset_or_next /*offset*/ = 0;
            o = tmp;
        }
    }

    assert(u < 0);
    *out_ = buckets;
    return 0;

J40__ON_ERROR:
    j40__free(buckets);
    return st.err;
}

int j40__ans_code(
    j40__st *st, uint *state, int log_bucket_size,
    const short *D, const j40__alias_bucket *aliases
) {
    if (*state == 0) {
        *state = cast(uint) j40__u(st, 16);
        *state |= cast(uint) j40__u(st, 16) << 16;
    }
    {
        int index = cast(int) (*state & 0xfff);
        int i = index >> log_bucket_size;
        int pos = index & ((1 << log_bucket_size) - 1);
        const j40__alias_bucket *bucket = &aliases[i];
        int symbol = pos < bucket.cutoff ? i : bucket.symbol;
        int offset = pos < bucket.cutoff ? 0 : bucket.offset_or_next /*offset*/;
        assert(D[symbol] != 0);
        *state = cast(uint) D[symbol] * (*state >> 12) + cast(uint) offset + cast(uint) pos;
        if (*state < (1u << 16)) *state = (*state << 16) | cast(uint) j40__u(st, 16);
        return symbol;
    }
}

////////////////////////////////////////////////////////////////////////////////
// entropy code

union j40__code_cluster
{
    j40__hybrid_int_config config;
    static struct init_t
    {
        j40__hybrid_int_config config;
        int count;
    } // only used during the initialization
    init_t init_;

    static struct ans_t
    {
        j40__hybrid_int_config config;
        short *D;
        j40__alias_bucket *aliases;
    } 
    ans_t ans; // if parent use_prefix_code is false

    static struct prefix_t 
    {
        j40__hybrid_int_config config;
        short fast_len, max_len;
        int *table;
    }
    prefix_t prefix; // if parent use_prefix_code is true
}

struct j40__code_spec // zero-initialized
{
    int num_dist = 0;
    int lz77_enabled = 0, 
        use_prefix_code = 0;
    int min_symbol = 0, 
        min_length = 0;
    int log_alpha_size = 0; // only used when use_prefix_code is false
    int num_clusters = 0; // in [1, min(num_dist, 256)]
    ubyte *cluster_map = null; // each in [0, num_clusters)
    j40__hybrid_int_config lz_len_config;
    j40__code_cluster *clusters = null;
}

struct j40__code_st // zero-initialized
{
    const(j40__code_spec)* spec = null;
    // LZ77 states
    int num_to_copy = 0, 
        copy_pos = 0, 
        num_decoded = 0;
    int window_cap = 0;
    int* window = null;
    // ANS state (SPEC there is a single such state throughout the whole ANS stream)
    uint ans_state = 0; // 0 if uninitialized
} ;

// j40__code dist_mult should be clamped to this value in order to prevent overflow
enum int J40__MAX_DIST_MULT = (1 << 21);

j40_err j40__cluster_map(j40__st *st, int num_dist, int max_allowed, 
                         int *num_clusters, ubyte **outmap) 
{
    j40__code_spec codespec; // cluster map might be recursively coded
    j40__code_st code;
    uint[8] seen = [0,0,0,0,0,0,0,0];
    ubyte *map = null;
    int i, j;

    assert(num_dist > 0);
    assert(max_allowed >= 1 && max_allowed <= 256);
    if (max_allowed > num_dist) max_allowed = num_dist;

    if (num_dist == 1) { // SPEC impossible in Brotli but possible (and unspecified) in JPEG XL
        *num_clusters = 1;

        *(outmap) =cast(ubyte*) j40__calloc(1, ubyte.sizeof);

        return 0;
    }

    *outmap = null;
    map = cast(ubyte*) j40__malloc(cast(size_t) num_dist, ubyte.sizeof);

    if (j40__u(st, 1)) { // is_simple (# clusters < 8)
        int nbits = j40__u(st, 2);
        for (i = 0; i < num_dist; ++i) {
            map[i] = cast(ubyte) j40__u(st, nbits);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((cast(int) map[i] < max_allowed) == 0)) { j40__set_error(st, J40__4("clst")); goto J40__ON_ERROR; } } while (0);
        }
    } else {
        int use_mtf = j40__u(st, 1);

        // TODO while num_dist is limited to 1, there is still a possibility of unbounded recursion
        // when each code spec introduces its own LZ77 distribution; libjxl doesn't allow LZ77
        // when cluster map is reading only two entries, which is technically incorrect but
        // easier to adopt in the current structure of J40 as well.
        do { if (J40_UNLIKELY(j40__read_code_spec(st, num_dist <= 2 ? -1 : 1, &codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__init_code(&code, &codespec);
        for (i = 0; i < num_dist; ++i) {
            int index = j40__code(st, 0, 0, &code); // SPEC context (always 0) is missing
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((index < max_allowed) == 0)) { j40__set_error(st, J40__4("clst")); goto J40__ON_ERROR; } } while (0);
            map[i] = cast(ubyte) index;
        }
        do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__free_code_spec(&codespec);

        if (use_mtf) {
            ubyte[256] mtf;
            ubyte moved;
            for (i = 0; i < 256; ++i) mtf[i] = cast(ubyte) i;
            for (i = 0; i < num_dist; ++i) {
                j = map[i];
                map[i] = moved = mtf[j];
                for (; j > 0; --j) mtf[j] = mtf[j - 1];
                mtf[0] = moved;
            }
        }
    }

    // verify cluster_map and determine the implicit num_clusters
    for (i = 0; i < num_dist; ++i) seen[map[i] >> 5] |= cast(uint) 1 << (map[i] & 31);
    for (i = 0; i < 256 && (seen[i >> 5] >> (i & 31) & 1); ++i){}
    *num_clusters = i; // the first unset position or 256 if none
    for (; i < 256 && !(seen[i >> 5] >> (i & 31) & 1); ++i){}
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((i == 256) == 0)) { j40__set_error(st, J40__4("clst")); goto J40__ON_ERROR; } } while (0); 
    assert(*num_clusters > 0);

    *outmap = map;
    return 0;

J40__ON_ERROR:
    j40__free(map);
    j40__free_code(&code);
    j40__free_code_spec(&codespec);
    return st.err;
}

j40_err j40__ans_table(j40__st *st, int log_alpha_size, short **outtable) 
{
    enum 
    { 
        DISTBITS = J40__DIST_BITS, 
        DISTSUM = 1 << DISTBITS 
    }
    int table_size = 1 << log_alpha_size;
    int i;
    short *D = null;

    D = cast(short*) malloc(cast(size_t) table_size * short.sizeof);

    switch (j40__u(st, 2)) { // two Bool() calls combined into u(2), so bits are swapped
    case 1: { // true . false case: one entry
        int v = j40__u8(st);
        memset(D, 0, short.sizeof * cast(size_t) table_size);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((v < table_size) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);
        D[v] = DISTSUM;
        break;
    }

    case 3: { // true . true case: two entries
        int v1 = j40__u8(st);
        int v2 = j40__u8(st);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((v1 != v2 && v1 < table_size && v2 < table_size) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);
        memset(D, 0, short.sizeof * cast(size_t) table_size);
        D[v1] = cast(short) j40__u(st, DISTBITS);
        D[v2] = cast(short) (DISTSUM - D[v1]);
        break;
    }

    case 2: { // false . true case: evenly distribute to first `alpha_size` entries
        int alpha_size = j40__u8(st) + 1;
        short d = cast(short) (DISTSUM / alpha_size);
        short bias_size = cast(short) (DISTSUM % alpha_size);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((alpha_size <= table_size) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);
        for (i = 0; i < bias_size; ++i) D[i] = cast(short) (d + 1);
        for (; i < alpha_size; ++i) D[i] = d;
        for (; i < table_size; ++i) D[i] = 0;
        break;
    }

    case 0: { // false . false case: bit counts + RLE
        int len, shift, alpha_size, omit_log, omit_pos, code, total, n;
        int[259] codes = void;
        int ncodes; // exponents if >= 0, negated repeat count if < 0

        len = j40__u(st, 1) ? j40__u(st, 1) ? j40__u(st, 1) ? 3 : 2 : 1 : 0;
        shift = j40__u(st, len) + (1 << len) - 1;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((shift <= 13) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);
        alpha_size = j40__u8(st) + 3;

        omit_log = -1; // there should be at least one non-RLE code
        for (i = ncodes = 0; i < alpha_size; ) 
        {
            static immutable int[20] TABLE = [ // reinterpretation of kLogCountLut
                0xa0003,     -16, 0x70003, 0x30004, 0x60003, 0x80003, 0x90003, 0x50004,
                0xa0003, 0x40004, 0x70003, 0x10004, 0x60003, 0x80003, 0x90003, 0x20004,
                0x00011, 0xb0022, 0xc0003, 0xd0043, // overflow for ...0001
            ];
            code = j40__prefix_code(st, 4, 7, TABLE.ptr);
            if (code < 13) {
                ++i;
                codes[ncodes++] = code;
                if (omit_log < code) omit_log = code;
            } else {
                i += code = j40__u8(st) + 4;
                codes[ncodes++] = -code;
            }
        }
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((i == alpha_size && omit_log >= 0) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);

        omit_pos = -1;
        for (i = n = total = 0; i < ncodes && n < table_size; ++i) {
            code = codes[i];
            if (code < 0) { // repeat
                short prev = n > 0 ? D[n - 1] : 0;
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((prev >= 0) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0); 
                code = j40__min32(-code, table_size - n);
                total += cast(int) prev * code;
                while (code-- > 0) D[n++] = prev;
            } else if (code == omit_log) { // the first longest D[n] is "omitted" (implicit)
                omit_pos = n;
                omit_log = -1; // this branch runs at most once
                D[n++] = -1;
            } else if (code < 2) {
                total += code;
                D[n++] = cast(short) code;
            } else {
                int bitcount;
                --code;
                bitcount = j40__min32(j40__max32(0, shift - ((DISTBITS - code) >> 1)), code);
                code = (1 << code) + (j40__u(st, bitcount) << (code - bitcount));
                total += code;
                D[n++] = cast(short) code;
            }
        }
        for (; n < table_size; ++n) D[n] = 0;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((omit_pos >= 0) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((total <= DISTSUM) == 0)) { j40__set_error(st, J40__4("ansd")); goto J40__ON_ERROR; } } while (0);
        D[omit_pos] = cast(short) (DISTSUM - total);
        break;
    }

    default: J40__UNREACHABLE();
    }

    *outtable = D;
    return 0;

J40__ON_ERROR:
    j40__free(D);
    return st.err;
}

// num_dist can be negative (and its absolute value is used) when a further use of LZ77 is disallowed
j40_err j40__read_code_spec(j40__st *st, int num_dist, j40__code_spec *spec) {
    int i;
    int allow_lz77;

    assert(num_dist != 0);
    allow_lz77 = (num_dist > 0);
    num_dist = j40__abs32(num_dist);

    spec.cluster_map = null;
    spec.clusters = null;

    // LZ77Params
    spec.lz77_enabled = j40__u(st, 1);
    if (spec.lz77_enabled) {
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((allow_lz77) == 0)) { j40__set_error(st, J40__4("lz77")); goto J40__ON_ERROR; } } while (0);
        spec.min_symbol = j40__u32(st, 224, 0, 512, 0, 4096, 0, 8, 15);
        spec.min_length = j40__u32(st, 3, 0, 4, 0, 5, 2, 9, 8);
        do { if (J40_UNLIKELY(j40__read_hybrid_int_config(st, 8, &spec.lz_len_config))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        ++num_dist; // num_dist - 1 is a synthesized LZ77 length distribution
    } else {
        spec.min_symbol = spec.min_length = 0x7fffffff;
    }

    // cluster_map: a mapping from context IDs to actual distributions
    do { if (J40_UNLIKELY(j40__cluster_map(st, num_dist, 256, &spec.num_clusters, &spec.cluster_map))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    spec.clusters = cast(j40__code_cluster*) j40__calloc(cast(size_t) spec.num_clusters, j40__code_cluster.sizeof);

    spec.use_prefix_code = j40__u(st, 1);
    if (spec.use_prefix_code) {
        for (i = 0; i < spec.num_clusters; ++i) { // SPEC the count is off by one
            do { if (J40_UNLIKELY(j40__read_hybrid_int_config(st, 15, &spec.clusters[i].config))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }

        for (i = 0; i < spec.num_clusters; ++i) {
            if (j40__u(st, 1)) {
                int n = j40__u(st, 4);
                spec.clusters[i].init_.count = 1 + (1 << n) + j40__u(st, n);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((spec.clusters[i].init_.count <= (1 << 15)) == 0)) { j40__set_error(st, J40__4("hufd")); goto J40__ON_ERROR; } } while (0);
            } else {
                spec.clusters[i].init_.count = 1;
            }
        }

        // SPEC this should happen after reading *all* count[i]
        for (i = 0; i < spec.num_clusters; ++i) {
            j40__code_cluster *c = &spec.clusters[i];
            int fast_len, max_len;
            do { if (J40_UNLIKELY(j40__prefix_code_tree(st, c.init_.count, &fast_len, &max_len, &c.prefix.table))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            c.prefix.fast_len = cast(short) fast_len;
            c.prefix.max_len = cast(short) max_len;
        }
    } else {
        spec.log_alpha_size = 5 + j40__u(st, 2);
        for (i = 0; i < spec.num_clusters; ++i) { // SPEC the count is off by one
            do { if (J40_UNLIKELY(j40__read_hybrid_int_config(st, spec.log_alpha_size, &spec.clusters[i].config))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }

        for (i = 0; i < spec.num_clusters; ++i) {
            j40__code_cluster *c = &spec.clusters[i];
            do { if (J40_UNLIKELY(j40__ans_table(st, spec.log_alpha_size, &c.ans.D))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(j40__init_alias_map(st, c.ans.D, spec.log_alpha_size, &c.ans.aliases))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
    }

    spec.num_dist = num_dist;
    return 0;

J40__ON_ERROR:
    j40__free_code_spec(spec);
    return st.err;
}

void j40__init_code(j40__code_st *code, const j40__code_spec *spec) 
{
    code.spec = spec;
    code.num_to_copy = code.copy_pos = code.num_decoded = 0;
    code.window_cap = 0;
    code.window = null;
    code.ans_state = 0;
}

int j40__entropy_code_cluster(
    j40__st *st, int use_prefix_code, int log_alpha_size,
    const(j40__code_cluster) *cluster, uint *ans_state
) {
    if (use_prefix_code) {
        return j40__prefix_code(st, cluster.prefix.fast_len, cluster.prefix.max_len, cluster.prefix.table);
    } else {
        return j40__ans_code(st, ans_state, J40__DIST_BITS - log_alpha_size, cluster.ans.D, cluster.ans.aliases);
    }
}

// aka DecodeHybridVarLenUint
int j40__code(j40__st *st, int ctx, int dist_mult, j40__code_st *code) {
    immutable int MASK = 0xfffff;

    const(j40__code_spec)* spec = code.spec;
    int token, distance, log_alpha_size;
    const(j40__code_cluster) *cluster;
    int use_prefix_code;

    if (code.num_to_copy > 0) {
        assert(code.window); // because this can't be the initial token and lz77_enabled is true
        --code.num_to_copy;
        return code.window[code.num_decoded++ & MASK] = code.window[code.copy_pos++ & MASK];
    }

    assert(ctx < spec.num_dist);
    use_prefix_code = spec.use_prefix_code;
    log_alpha_size = spec.log_alpha_size;
    cluster = &spec.clusters[spec.cluster_map[ctx]];
    token = j40__entropy_code_cluster(st, use_prefix_code, log_alpha_size, cluster, &code.ans_state);
    if (token >= spec.min_symbol) { // this is large enough if lz77_enabled is false
        const(j40__code_cluster)* lz_cluster = &spec.clusters[spec.cluster_map[spec.num_dist - 1]];
        int num_to_copy = j40__hybrid_int(st, token - spec.min_symbol, spec.lz_len_config) + spec.min_length;
        token = j40__entropy_code_cluster(st, use_prefix_code, log_alpha_size, lz_cluster, &code.ans_state);
        distance = j40__hybrid_int(st, token, lz_cluster.config);
        if (st.err) return 0;
        if (!dist_mult) {
            ++distance;
        } else if (distance >= 120) {
            distance -= 119;
        } else {
            static immutable ubyte[120] SPECIAL_DISTANCES = [ // {a,b} encoded as (a+7)*16+b
                0x71, 0x80, 0x81, 0x61, 0x72, 0x90, 0x82, 0x62, 0x91, 0x51, 0x92, 0x52,
                0x73, 0xa0, 0x83, 0x63, 0xa1, 0x41, 0x93, 0x53, 0xa2, 0x42, 0x74, 0xb0,
                0x84, 0x64, 0xb1, 0x31, 0xa3, 0x43, 0x94, 0x54, 0xb2, 0x32, 0x75, 0xa4,
                0x44, 0xb3, 0x33, 0xc0, 0x85, 0x65, 0xc1, 0x21, 0x95, 0x55, 0xc2, 0x22,
                0xb4, 0x34, 0xa5, 0x45, 0xc3, 0x23, 0x76, 0xd0, 0x86, 0x66, 0xd1, 0x11,
                0x96, 0x56, 0xd2, 0x12, 0xb5, 0x35, 0xc4, 0x24, 0xa6, 0x46, 0xd3, 0x13,
                0x77, 0xe0, 0x87, 0x67, 0xc5, 0x25, 0xe1, 0x01, 0xb6, 0x36, 0xd4, 0x14,
                0x97, 0x57, 0xe2, 0x02, 0xa7, 0x47, 0xe3, 0x03, 0xc6, 0x26, 0xd5, 0x15,
                0xf0, 0xb7, 0x37, 0xe4, 0x04, 0xf1, 0xf2, 0xd6, 0x16, 0xf3, 0xc7, 0x27,
                0xe5, 0x05, 0xf4, 0xd7, 0x17, 0xe6, 0x06, 0xf5, 0xe7, 0x07, 0xf6, 0xf7,
            ];
            int special = cast(int) SPECIAL_DISTANCES[distance];
            assert(dist_mult <= J40__MAX_DIST_MULT);
            // TODO spec bug: distance can be as low as -6 when dist_mult = 1 and distance =
            // dist_mult * 1 - 7; libjxl clamps it to the minimum of 1, so we do the same here
            distance = j40__max32(1, ((special >> 4) - 7) + dist_mult * (special & 7));
        }
        distance = j40__min32(j40__min32(distance, code.num_decoded), 1 << 20);
        code.copy_pos = code.num_decoded - distance;
        if (J40_UNLIKELY(distance == 0)) 
        {
            // TODO spec bug: this is possible when num_decoded == 0 (or a non-positive special
            // distance, handled above) and libjxl acts as if `window[i]` is initially filled with 0
            assert(code.num_decoded == 0 && !code.window);
            code.window = cast(int*) j40__calloc(1u << 20, int.sizeof);
            if (!code.window) 
            {
                j40__set_error(st, J40__4("!mem"));
                return 0;
            }
        }
        assert(num_to_copy > 0);
        code.num_to_copy = num_to_copy - 1;
        return code.window[code.num_decoded++ & MASK] = code.window[code.copy_pos++ & MASK];
    }

    token = j40__hybrid_int(st, token, cluster.config);
    if (st.err) return 0;
    if (spec.lz77_enabled) {
        if (!code.window) 
        { 
            // XXX should be dynamically resized
            code.window = cast(int*) j40__malloc(1u << 20, int.sizeof);
            if (!code.window) 
            {
                j40__set_error(st, J40__4("!mem"));
                return 0;
            }
        }
        code.window[code.num_decoded++ & MASK] = token;
    }
    return token;
}

void j40__free_code(j40__code_st *code) 
{
    j40__free(code.window);
    code.window = null;
    code.window_cap = 0;
}

j40_err j40__finish_and_free_code(j40__st *st, j40__code_st *code) 
{
    if (!code.spec.use_prefix_code) {
        if (code.ans_state) {
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((code.ans_state == J40__ANS_INIT_STATE) == 0)) { j40__set_error(st, J40__4("ans?")); goto J40__ON_ERROR; } } while (0);
        } else { // edge case: if no symbols have been read the state has to be read at this point
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__u(st, 16) == (J40__ANS_INIT_STATE & 0xffff)) == 0)) { j40__set_error(st, J40__4("ans?")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__u(st, 16) == (J40__ANS_INIT_STATE >> 16)) == 0)) { j40__set_error(st, J40__4("ans?")); goto J40__ON_ERROR; } } while (0);
        }
    }
    // it's explicitly allowed that num_to_copy can be > 0 at the end of stream
J40__ON_ERROR:
    j40__free_code(code);
    return st.err;
}

void j40__free_code_spec(j40__code_spec *spec) {
    int i;
    if (spec.clusters) {
        for (i = 0; i < spec.num_clusters; ++i) {
            if (spec.use_prefix_code) {
                j40__free(spec.clusters[i].prefix.table);
            } else {
                j40__free(spec.clusters[i].ans.D);
                j40__free(spec.clusters[i].ans.aliases);
            }
        }
        j40__free(spec.clusters);
        spec.clusters = null;
    }
    j40__free(spec.cluster_map);
    spec.cluster_map = null;
}

////////////////////////////////////////////////////////////////////////////////
// image header & metadata

enum : int 
{
    J40__CHROMA_WHITE = 0, J40__CHROMA_RED = 1,
    J40__CHROMA_GREEN = 2, J40__CHROMA_BLUE = 3,
}

alias j40__ec_type = int;
enum : j40__ec_type
{
    J40__EC_ALPHA = 0, 
    J40__EC_DEPTH = 1, 
    J40__EC_SPOT_COLOUR = 2,
    J40__EC_SELECTION_MASK = 3, 
    J40__EC_BLACK = 4, 
    J40__EC_CFA = 5,
    J40__EC_THERMAL = 6, 
    J40__EC_NON_OPTIONAL = 15, 
    J40__EC_OPTIONAL = 16,
}

struct j40__ec_info
{
    j40__ec_type type;
    int bpp, exp_bits, dim_shift, name_len;
    char *name;
    union data_t
    {
        int alpha_associated;
        static struct spot_t
        {
            float red, green, blue, solidity;
        }
        spot_t spot;
        int cfa_channel;
    }
    data_t data;
}

alias j40__orientation = int;
enum : j40__orientation 
{
    J40__ORIENT_TL = 1, J40__ORIENT_TR = 2, J40__ORIENT_BR = 3, J40__ORIENT_BL = 4,
    J40__ORIENT_LT = 5, J40__ORIENT_RT = 6, J40__ORIENT_RB = 7, J40__ORIENT_LB = 8,
}

alias j40__cspace = int;
enum : j40__cspace 
{
    J40__CS_CHROMA = 'c', J40__CS_GREY = 'g', J40__CS_XYB = 'x',
}

enum : int
{ // for `j40__image_st.gamma_or_tf`
    J40__TF_709 = -1, J40__TF_UNKNOWN = -2, J40__TF_LINEAR = -8, J40__TF_SRGB = -13,
    J40__TF_PQ = -16, J40__TF_DCI = -17, J40__TF_HLG = -18,
    J40__GAMMA_MAX = 10000000,
}

alias j40__render_intent = int;
enum : j40__render_intent
{
    J40__INTENT_PERC = 0, 
    J40__INTENT_REL = 1, 
    J40__INTENT_SAT = 2, 
    J40__INTENT_ABS = 3
}

struct j40__image_st 
{
    int width, height;
    j40__orientation orientation;
    int intr_width, intr_height; // 0 if not specified
    int bpp, exp_bits;

    int anim_tps_num, anim_tps_denom; // num=denom=0 if not animated
    long anim_nloops; // 0 if infinity
    int anim_have_timecodes;

    char *icc;
    size_t iccsize;
    j40__cspace cspace;
    float[2 /*x=0, y=1*/][4 /*J40__CHROMA_xxx*/] cpoints; // only for J40__CS_CHROMA
    int gamma_or_tf; // gamma if > 0, transfer function if <= 0
    j40__render_intent render_intent;
    float intensity_target, min_nits; // 0 < min_nits <= intensity_target
    float linear_below; // absolute (nits) if >= 0; a negated ratio of max display brightness if [-1,0]

    int modular_16bit_buffers;
    int num_extra_channels;
    j40__ec_info *ec_info;
    int xyb_encoded;
    float[3][3] opsin_inv_mat;
    float[3] opsin_bias;
    float[3 /*xyb*/] quant_bias;
    float quant_bias_num;
    int want_icc;
}

j40_err j40__signature(j40__st *st) 
{
    int sig = j40__u(st, 16);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((sig == 0x0aff) == 0)) { j40__set_error(st, J40__4("!jxl")); goto J40__ON_ERROR; } } while (0); // FF 0A in the byte sequence
J40__ON_ERROR:
    return st.err;
}

j40_err j40__size_header(j40__st *st, int *outw, int *outh) 
{
    int div8 = j40__u(st, 1);
    *outh = div8 ? (j40__u(st, 5) + 1) * 8 : j40__u32(st, 1, 9, 1, 13, 1, 18, 1, 30);
    switch (j40__u(st, 3)) { // ratio
    case 0: *outw = div8 ? (j40__u(st, 5) + 1) * 8 : j40__u32(st, 1, 9, 1, 13, 1, 18, 1, 30); break;
    case 1: *outw = *outh; break;
    case 2: *outw = cast(int) (cast(ulong) *outh * 6 / 5); break;
    case 3: *outw = cast(int) (cast(ulong) *outh * 4 / 3); break;
    case 4: *outw = cast(int) (cast(ulong) *outh * 3 / 2); break;
    case 5: *outw = cast(int) (cast(ulong) *outh * 16 / 9); break;
    case 6: *outw = cast(int) (cast(ulong) *outh * 5 / 4); break;
    case 7:
        // height is at most 2^30, so width is at most 2^31 which requires uint.
        // but in order to avoid bugs we rarely use unsigned integers, so we just reject it.
        // this should be not a problem as the Main profile Level 10 (the largest profile)
        // already limits height to at most 2^30.
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((*outh < 0x40000000) == 0)) { j40__set_error(st, J40__4("bigg")); goto J40__ON_ERROR; } } while (0);
        *outw = *outh * 2;
        break;
    default: J40__UNREACHABLE();
    }
J40__ON_ERROR:
    return st.err;
}

j40_err j40__bit_depth(j40__st *st, int *outbpp, int *outexpbits) {
    if (j40__u(st, 1)) { // float_sample
        int mantissa_bits;
        *outbpp = j40__u32(st, 32, 0, 16, 0, 24, 0, 1, 6);
        *outexpbits = j40__u(st, 4) + 1;
        mantissa_bits = *outbpp - *outexpbits - 1;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((2 <= mantissa_bits && mantissa_bits <= 23) == 0)) { j40__set_error(st, J40__4("bpp?")); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((2 <= *outexpbits && *outexpbits <= 8) == 0)) { j40__set_error(st, J40__4("exp?")); goto J40__ON_ERROR; } } while (0);   // implies bpp in [5,32] when combined
    } else {
        *outbpp = j40__u32(st, 8, 0, 10, 0, 12, 0, 1, 6);
        *outexpbits = 0;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((1 <= *outbpp && *outbpp <= 31) == 0)) { j40__set_error(st, J40__4("bpp?")); goto J40__ON_ERROR; } } while (0);
    }
J40__ON_ERROR:
    return st.err;
}

j40_err j40__name(j40__st *st, int *outlen, char **outbuf) 
 {
    char *buf = null;
    int i, c, cc, len;
    len = j40__u32(st, 0, 0, 0, 4, 16, 5, 48, 10);
    if (len > 0) 
    {

        buf = cast(char*) j40__malloc(cast(size_t) len + 1, char.sizeof);

        for (i = 0; i < len; ++i) {
            buf[i] = cast(char) j40__u(st, 8);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
        }
        buf[len] = 0;
        for (i = 0; i < len; ) 
        { // UTF-8 verification
            c = cast(ubyte) buf[i++];
            cc = cast(ubyte) buf[i]; // always accessible thanks to null-termination
            c = c < 0x80 ? 0 : c < 0xc2 ? -1 : c < 0xe0 ? 1 :
                c < 0xf0 ? (c == 0xe0 ? cc >= 0xa0 : c == 0xed ? cc < 0xa0 : 1) ? 2 : -1 :
                c < 0xf5 ? (c == 0xf0 ? cc >= 0x90 : c == 0xf4 ? cc < 0x90 : 1) ? 3 : -1 : -1;
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((c >= 0 && i + c < len) == 0)) { j40__set_error(st, J40__4("name")); goto J40__ON_ERROR; } } while (0);
            while (c-- > 0) do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY(((buf[i++] & 0xc0) == 0x80) == 0)) { j40__set_error(st, J40__4("name")); goto J40__ON_ERROR; } } while (0);
        }
        *outbuf = buf;
    } else {
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
        *outbuf = null;
    }
    *outlen = len;
    return 0;
J40__ON_ERROR:
    j40__free(buf);
    return st.err;
}

j40_err j40__customxy(j40__st *st, float* xy) 
{
    xy[0] = cast(float)j40__unpack_signed(j40__u32(st, 0, 19, 0x80000, 19, 0x100000, 20, 0x200000, 21)) / 100000.0f;
    xy[1] = cast(float)j40__unpack_signed(j40__u32(st, 0, 19, 0x80000, 19, 0x100000, 20, 0x200000, 21)) / 100000.0f;
    return st.err;
}

j40_err j40__extensions(j40__st *st) {
    ulong extensions = j40__u64(st);
    long nbits = 0;
    int i;
    for (i = 0; i < 64; ++i) {
        if (extensions >> i & 1) {
            ulong n = j40__u64(st);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((n <= cast(ulong) INT64_MAX && j40__add64(nbits, cast(long) n, &nbits)) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);
        }
    }
    return j40__skip(st, nbits);
J40__ON_ERROR:
    return st.err;
}

j40_err j40__image_metadata(j40__st *st) 
{
    static immutable float[2][4] SRGB_CHROMA = [ // default chromacity (kD65, kSRGB)
        [0.3127f, 0.3290f], 
        [0.639998686f, 0.330010138f],
        [0.300003784f, 0.600003357f], 
        [0.150002046f, 0.059997204f],
    ];
    static immutable float[3][3] OPSIN_INV_MAT = [ // default opsin inverse matrix
        [11.031566901960783f, -9.866943921568629f, -0.16462299647058826f],
        [-3.254147380392157f, 4.418770392156863f, -0.16462299647058826f],
        [-3.6588512862745097f, 2.7129230470588235f, 1.9459282392156863f],
    ];

    j40__image_st *im = st.image;
    int i, j;

    im.orientation = J40__ORIENT_TL;
    im.intr_width = 0;
    im.intr_height = 0;
    im.bpp = 8;
    im.exp_bits = 0;
    im.anim_tps_num = 0;
    im.anim_tps_denom = 0;
    im.anim_nloops = 0;
    im.anim_have_timecodes = 0;
    im.icc = null;
    im.iccsize = 0;
    im.cspace = J40__CS_CHROMA;
    memcpy(im.cpoints.ptr, SRGB_CHROMA.ptr, SRGB_CHROMA.sizeof);
    im.gamma_or_tf = J40__TF_SRGB;
    im.render_intent = J40__INTENT_REL;
    im.intensity_target = 255.0f;
    im.min_nits = 0.0f;
    im.linear_below = 0.0f;
    im.modular_16bit_buffers = 1;
    im.xyb_encoded = 1;
    memcpy(im.opsin_inv_mat.ptr, OPSIN_INV_MAT.ptr, OPSIN_INV_MAT.sizeof);
    im.opsin_bias[0] = im.opsin_bias[1] = im.opsin_bias[2] = -0.0037930732552754493f;
    im.quant_bias[0] = 1.0f - 0.05465007330715401f;
    im.quant_bias[1] = 1.0f - 0.07005449891748593f;
    im.quant_bias[2] = 1.0f - 0.049935103337343655f;
    im.quant_bias_num = 0.145f;

    do { if (J40_UNLIKELY(j40__size_header(st, &im.width, &im.height))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.width <= st.limits.width && im.height <= st.limits.height) == 0)) { j40__set_error(st, J40__4("slim")); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((cast(long) im.width * im.height <= st.limits.pixels) == 0)) { j40__set_error(st, J40__4("slim")); goto J40__ON_ERROR; } } while (0);

    if (!j40__u(st, 1)) { // !all_default
        int extra_fields = j40__u(st, 1);
        if (extra_fields) {
            im.orientation = cast(j40__orientation) (j40__u(st, 3) + 1);
            if (j40__u(st, 1)) { // have_intr_size
                do { if (J40_UNLIKELY(j40__size_header(st, &im.intr_width, &im.intr_height))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            }
            if (j40__u(st, 1)) { // have_preview
                do { j40__set_error(st, J40__4("TODO: preview")); goto J40__ON_ERROR; } while (0);
            }
            if (j40__u(st, 1)) { // have_animation
                im.anim_tps_num = j40__u32(st, 100, 0, 1000, 0, 1, 10, 1, 30);
                im.anim_tps_denom = j40__u32(st, 1, 0, 1001, 0, 1, 8, 1, 10);
                im.anim_nloops = j40__64u32(st, 0, 0, 0, 3, 0, 16, 0, 32);
                im.anim_have_timecodes = j40__u(st, 1);
            }
        }
        do { if (J40_UNLIKELY(j40__bit_depth(st, &im.bpp, &im.exp_bits))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.bpp <= st.limits.bpp) == 0)) { j40__set_error(st, J40__4("fbpp")); goto J40__ON_ERROR; } } while (0);
        im.modular_16bit_buffers = j40__u(st, 1);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.modular_16bit_buffers || !st.limits.needs_modular_16bit_buffers) == 0)) { j40__set_error(st, J40__4("fm32")); goto J40__ON_ERROR; } } while (0);
        im.num_extra_channels = j40__u32(st, 0, 0, 1, 0, 2, 4, 1, 12);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.num_extra_channels <= st.limits.num_extra_channels) == 0)) { j40__set_error(st, J40__4("elim")); goto J40__ON_ERROR; } } while (0);

        im.ec_info = cast(j40__ec_info*) j40__calloc(cast(size_t) im.num_extra_channels, j40__ec_info.sizeof);

        for (i = 0; i < im.num_extra_channels; ++i) im.ec_info[i].name = null;
        for (i = 0; i < im.num_extra_channels; ++i) {
            j40__ec_info *ec = &im.ec_info[i];
            if (j40__u(st, 1)) { // d_alpha
                ec.type = J40__EC_ALPHA;
                ec.bpp = 8;
                ec.exp_bits = ec.dim_shift = ec.name_len = 0;
                ec.data.alpha_associated = 0;
            } else {
                ec.type = cast(j40__ec_type) j40__enum(st);
                do { if (J40_UNLIKELY(j40__bit_depth(st, &ec.bpp, &ec.exp_bits))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                ec.dim_shift = j40__u32(st, 0, 0, 3, 0, 4, 0, 1, 3);
                do { if (J40_UNLIKELY(j40__name(st, &ec.name_len, &ec.name))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                switch (ec.type) {
                case J40__EC_ALPHA:
                    ec.data.alpha_associated = j40__u(st, 1);
                    break;
                case J40__EC_SPOT_COLOUR:
                    ec.data.spot.red = j40__f16(st);
                    ec.data.spot.green = j40__f16(st);
                    ec.data.spot.blue = j40__f16(st);
                    ec.data.spot.solidity = j40__f16(st);
                    break;
                case J40__EC_CFA:
                    ec.data.cfa_channel = j40__u32(st, 1, 0, 0, 2, 3, 4, 19, 8);
                    break;
                case J40__EC_BLACK:
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((st.limits.ec_black_allowed) == 0)) { j40__set_error(st, J40__4("fblk")); goto J40__ON_ERROR; } } while (0);
                    break;
                case J40__EC_DEPTH: case J40__EC_SELECTION_MASK:
                case J40__EC_THERMAL: case J40__EC_NON_OPTIONAL: case J40__EC_OPTIONAL:
                    break;
                default: do { j40__set_error(st, J40__4("ect?")); goto J40__ON_ERROR; } while (0);
                }
            }
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((ec.bpp <= st.limits.bpp) == 0)) { j40__set_error(st, J40__4("fbpp")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
        }
        im.xyb_encoded = j40__u(st, 1);
        if (!j40__u(st, 1)) 
        { // ColourEncoding.all_default
            alias cspace_t = int;
            enum : cspace_t
            { 
                CS_RGB = 0, 
                CS_GREY = 1, 
                CS_XYB = 2, 
                CS_UNKNOWN = 3 
            }
            cspace_t cspace;

            enum { WP_D65 = 1, WP_CUSTOM = 2, WP_E = 10, WP_DCI = 11 }
            enum { PR_SRGB = 1, PR_CUSTOM = 2, PR_2100 = 9, PR_P3 = 11 }
            im.want_icc = j40__u(st, 1);
            cspace = cast(cspace_t) j40__enum(st);
            switch (cspace) 
            {
            case CS_RGB: case CS_UNKNOWN: im.cspace = J40__CS_CHROMA; break;
            case CS_GREY: im.cspace = J40__CS_GREY; break;
            case CS_XYB: im.cspace = J40__CS_XYB; break;
            default: do { j40__set_error(st, J40__4("csp?")); goto J40__ON_ERROR; } while (0);
            }
            // TODO: should verify cspace grayness with ICC grayness
            if (!im.want_icc) 
            {
                if (cspace != CS_XYB) 
                {
                    static immutable float[2] E = [1/3.0f, 1/3.0f]; 
                    static immutable float[2] DCI = [0.314f, 0.351f];
                    static immutable float[2][3] BT2100 = [[0.708f, 0.292f], [0.170f, 0.797f], [0.131f, 0.046f]];
                    static immutable float[2][3] P3 = [[0.680f, 0.320f], [0.265f, 0.690f], [0.150f, 0.060f]];
                    switch (j40__enum(st)) 
                    {
                    case WP_D65: 
                        break; // default
                    case WP_CUSTOM: 
                        do { if (J40_UNLIKELY(j40__customxy(st, im.cpoints[J40__CHROMA_WHITE].ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0); 
                        break;
                    case WP_E: 
                        memcpy(im.cpoints.ptr + J40__CHROMA_WHITE, E.ptr, E.sizeof); 
                        break;
                    case WP_DCI: 
                        memcpy(im.cpoints.ptr + J40__CHROMA_WHITE, DCI.ptr, DCI.sizeof); 
                        break;
                    default: do { j40__set_error(st, J40__4("wpt?")); goto J40__ON_ERROR; } while (0);
                    }
                    if (cspace != CS_GREY) 
                    {
                        switch (j40__enum(st)) {
                        case PR_SRGB: break; // default
                        case PR_CUSTOM:
                            do { if (J40_UNLIKELY(j40__customxy(st, im.cpoints[J40__CHROMA_RED].ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                            do { if (J40_UNLIKELY(j40__customxy(st, im.cpoints[J40__CHROMA_GREEN].ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                            do { if (J40_UNLIKELY(j40__customxy(st, im.cpoints[J40__CHROMA_BLUE].ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                            break;
                        case PR_2100: 
                            memcpy(im.cpoints.ptr + J40__CHROMA_RED, BT2100.ptr, BT2100.sizeof); break;
                        case PR_P3: memcpy(im.cpoints.ptr + J40__CHROMA_RED, P3.ptr, P3.sizeof); break;
                        default: do { j40__set_error(st, J40__4("prm?")); goto J40__ON_ERROR; } while (0);
                        }
                    }
                }
                if (j40__u(st, 1)) { // have_gamma
                    im.gamma_or_tf = j40__u(st, 24);
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.gamma_or_tf > 0 && im.gamma_or_tf <= J40__GAMMA_MAX) == 0)) { j40__set_error(st, J40__4("gama")); goto J40__ON_ERROR; } } while (0);
                    if (cspace == CS_XYB) do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.gamma_or_tf == 3333333) == 0)) { j40__set_error(st, J40__4("gama")); goto J40__ON_ERROR; } } while (0);
                } else {
                    im.gamma_or_tf = -j40__enum(st);
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((( 1 << -J40__TF_709 | 1 << -J40__TF_UNKNOWN | 1 << -J40__TF_LINEAR | 1 << -J40__TF_SRGB | 1 << -J40__TF_PQ | 1 << -J40__TF_DCI | 1 << -J40__TF_HLG ) >> -im.gamma_or_tf & 1) == 0)) { j40__set_error(st, J40__4("tfn?")); goto J40__ON_ERROR; } } while (0);
                }
                im.render_intent = cast(j40__render_intent) j40__enum(st);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((( 1 << J40__INTENT_PERC | 1 << J40__INTENT_REL | 1 << J40__INTENT_SAT | 1 << J40__INTENT_ABS ) >> im.render_intent & 1) == 0)) { j40__set_error(st, J40__4("itt?")); goto J40__ON_ERROR; } } while (0);
            }
        }
        if (extra_fields) {
            if (!j40__u(st, 1)) { // ToneMapping.all_default
                int relative_to_max_display;
                im.intensity_target = j40__f16(st);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.intensity_target > 0) == 0)) { j40__set_error(st, J40__4("tone")); goto J40__ON_ERROR; } } while (0);
                im.min_nits = j40__f16(st);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((0 < im.min_nits && im.min_nits <= im.intensity_target) == 0)) { j40__set_error(st, J40__4("tone")); goto J40__ON_ERROR; } } while (0);
                relative_to_max_display = j40__u(st, 1);
                im.linear_below = j40__f16(st);
                if (relative_to_max_display) {
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((0 <= im.linear_below && im.linear_below <= 1) == 0)) { j40__set_error(st, J40__4("tone")); goto J40__ON_ERROR; } } while (0);
                    im.linear_below *= -1.0f;
                } else {
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((0 <= im.linear_below) == 0)) { j40__set_error(st, J40__4("tone")); goto J40__ON_ERROR; } } while (0);
                }
            }
        }
        do { if (J40_UNLIKELY(j40__extensions(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
    if (!j40__u(st, 1)) { // !default_m
        int cw_mask;
        if (im.xyb_encoded) {
            for (i = 0; i < 3; ++i) for (j = 0; j < 3; ++j) im.opsin_inv_mat[i][j] = j40__f16(st);
            for (i = 0; i < 3; ++i) im.opsin_bias[i] = j40__f16(st);
            for (i = 0; i < 3; ++i) im.quant_bias[i] = j40__f16(st);
            im.quant_bias_num = j40__f16(st);
        }
        cw_mask = j40__u(st, 3);
        if (cw_mask & 1) {
            do { j40__set_error(st, J40__4("TODO: up2_weight")); goto J40__ON_ERROR; } while (0);
        }
        if (cw_mask & 2) {
            do { j40__set_error(st, J40__4("TODO: up4_weight")); goto J40__ON_ERROR; } while (0);
        }
        if (cw_mask & 4) {
            do { j40__set_error(st, J40__4("TODO: up8_weight")); goto J40__ON_ERROR; } while (0);
        }
    }
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
    return 0;

J40__ON_ERROR:
    return st.err;
}

void j40__free_image_state(j40__image_st *im) 
{
    int i;
    if (im.ec_info) {
        for (i = 0; i < im.num_extra_channels; ++i) j40__free(im.ec_info[i].name);
        j40__free(im.ec_info);
        im.ec_info = null;
    }
    j40__free(im.icc);
    im.icc = null;
    im.num_extra_channels = 0;
}

////////////////////////////////////////////////////////////////////////////////
// ICC

ulong j40__icc_varint(j40__st *st, ulong *index, ulong size, j40__code_st *code) 
{
    ulong value = 0;
    int shift = 0;
    do 
    {
        int b;
        if ((*index)++ >= size)
        {
            j40__set_error(st, J40__4("icc?"));
            return 0;  
        }
        b = j40__code(st, 0, 0, code);
        value |= cast(ulong) (b & 0x7f) << shift;
        if (b < 128) return value;
        shift += 7;
    } while (shift < 63);
    j40__set_error(st, J40__4("vint"));
    return 0;
}

j40_err j40__icc(j40__st *st) 
{
    ulong enc_size, output_size, index;
    j40__code_spec codespec;
    j40__code_st code;
    int byte_ = 0, prev = 0, pprev = 0, ctx;

    enc_size = j40__u64(st);
    do { if (J40_UNLIKELY(j40__read_code_spec(st, 41, &codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    j40__init_code(&code, &codespec);

    index = 0;
    output_size = j40__icc_varint(st, &index, enc_size, &code);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((output_size <= st.limits.icc_output_size) == 0)) { j40__set_error(st, J40__4("plim")); goto J40__ON_ERROR; } } while (0);

    // SPEC it is still possible that enc_size is too large while output_size is within the limit.
    // the current spec allows for an arbitrarily large enc_size for the fixed output_size, because
    // some commands can generate zero output bytes, but as libjxl never emits such commands and
    // already (wrongly) assumes that a single command byte can generate at least one output byte,
    // J40 instead chose to forbid such commands. with this restriction in place valid enc_size
    // can never exceed 21 times output_size, so this is what we are checking for.
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((output_size >= enc_size / 21) == 0)) { j40__set_error(st, J40__4("icc?")); goto J40__ON_ERROR; } } while (0);

    for (; index < enc_size; ++index) {
        pprev = prev;
        prev = byte_;
        ctx = 0;
        if (index > 128) {
            if (prev < 16) ctx = prev < 2 ? prev + 3 : 5;
            else if (prev > 240) ctx = 6 + (prev == 255);
            else if (97 <= (prev | 32) && (prev | 32) <= 122) ctx = 1;
            else if (prev == 44 || prev == 46 || (48 <= prev && prev < 58)) ctx = 2;
            else ctx = 8;
            if (pprev < 16) ctx += 2 * 8;
            else if (pprev > 240) ctx += 3 * 8;
            else if (97 <= (pprev | 32) && (pprev | 32) <= 122) ctx += 0 * 8;
            else if (pprev == 44 || pprev == 46 || (48 <= pprev && pprev < 58)) ctx += 1 * 8;
            else ctx += 4 * 8;
        }
        byte_ = j40__code(st, ctx, 0, &code);
        //printf("%zd/%zd: %zd ctx=%d byte=%#x %c\n", index, enc_size, j40__bits_read(st), ctx, (int)byte_, 0x20 <= byte && byte < 0x7f ? byte : ' '); fflush(stdout);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
        // TODO actually interpret them
    }
    do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    j40__free_code_spec(&codespec);

    //size_t commands_size = j40__varint(st);

    /*
    static const char PREDICTIONS[] = {
        '*', '*', '*', '*', 0, 0, 0, 0, 4, 0, 0, 0, 'm', 'n', 't', 'r',
        'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' ', 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 'a', 'c', 's', 'p', 0, '@', '@', '@', 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 246, 214, 0, 1, 0, 0, 0, 0, 211, 45,
        '#', '#', '#', '#',
    };
    char pred = i < sizeof(PREDICTIONS) ? PREDICTIONS[i] : 0;
    switch (pred) {
    case '*': pred = output_size[i]; break;
    case '#': pred = header[i - 76]; break;
    case '@':
        switch (header[40]) {
        case 'A': pred = "APPL"[i - 40]; break;
        case 'M': pred = "MSFT"[i - 40]; break;
        case 'S':
            switch (i < 41 ? 0 : header[41]) {
            case 'G': pred = "SGI "[i - 40]; break;
            case 'U': pred = "SUNW"[i - 40]; break;
            }
            break;
        }
        break;
    }
    */

    return 0;

J40__ON_ERROR:
    j40__free_code(&code);
    j40__free_code_spec(&codespec);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// MA tree

enum { J40__NUM_PRED = 14 };

union j40__tree_node
{
    static struct branch_t 
    {
        int prop; // < 0, ~prop is the property index (e.g. -1 = channel index)
        int value;
        int leftoff, rightoff; // relative to the current node
    } 
    branch_t branch;
    static struct leaf_t 
    {
        int ctx; // >= 0
        int predictor;
        int offset, multiplier;
    } 
    leaf_t leaf;
}

j40_err j40__tree(
    j40__st *st, int max_tree_size, j40__tree_node **tree, j40__code_spec *codespec
);

j40_err j40__tree(
    j40__st *st, int max_tree_size, j40__tree_node **tree, j40__code_spec *codespec
) {
    j40__code_st code;
    j40__tree_node *t = null;
    int tree_idx = 0, tree_cap = 8;
    int ctx_id = 0, nodes_left = 1;
    int depth = 0, nodes_upto_this_depth = 1;

    assert(max_tree_size <= (1 << 26)); // codestream limit; the actual limit should be smaller

    do { if (J40_UNLIKELY(j40__read_code_spec(st, 6, codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    j40__init_code(&code, codespec);
    t = cast(j40__tree_node*) j40__malloc(cast(size_t) tree_cap, j40__tree_node.sizeof);
    while (nodes_left-- > 0) { // depth-first, left-to-right ordering
        j40__tree_node *n;
        int prop, val, shift;

        // the beginning of new tree depth; all `nodes_left` nodes are in this depth at the moment
        if (tree_idx == nodes_upto_this_depth) {
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((++depth <= st.limits.tree_depth) == 0)) { j40__set_error(st, J40__4("tlim")); goto J40__ON_ERROR; } } while (0);
            nodes_upto_this_depth += nodes_left + 1;
        }

        prop = j40__code(st, 1, 0, &code);

        t = cast(j40__tree_node*) j40__realloc32(st, t, j40__tree_node.sizeof, tree_idx + 1, &tree_cap);
      
       
        n = &t[tree_idx++];
        if (prop > 0) {
            n.branch.prop = -prop;
            n.branch.value = j40__unpack_signed(j40__code(st, 0, 0, &code));
            n.branch.leftoff = ++nodes_left;
            n.branch.rightoff = ++nodes_left;
        } else {
            n.leaf.ctx = ctx_id++;
            n.leaf.predictor = j40__code(st, 2, 0, &code);
            n.leaf.offset = j40__unpack_signed(j40__code(st, 3, 0, &code));
            shift = j40__code(st, 4, 0, &code);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((shift < 31) == 0)) { j40__set_error(st, J40__4("tree")); goto J40__ON_ERROR; } } while (0);
            val = j40__code(st, 5, 0, &code);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((((val + 1) >> (31 - shift)) == 0) == 0)) { j40__set_error(st, J40__4("tree")); goto J40__ON_ERROR; } } while (0);
            n.leaf.multiplier = (val + 1) << shift;
        }

        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((tree_idx + nodes_left <= max_tree_size) == 0)) { j40__set_error(st, J40__4("tlim")); goto J40__ON_ERROR; } } while (0);
    }
    assert(tree_idx == nodes_upto_this_depth);
    if (J40_UNLIKELY(j40__finish_and_free_code(st, &code))) { assert(st.err); goto J40__ON_ERROR; }

    j40__free_code_spec(codespec);
    memset(codespec, 0, (*codespec).sizeof); // XXX is it required?
    if (J40_UNLIKELY(j40__read_code_spec(st, ctx_id, codespec))) { assert(st.err); goto J40__ON_ERROR; }
    *tree = t;
    return 0;

J40__ON_ERROR:
    j40__free(t);
    j40__free_code(&code);
    j40__free_code_spec(codespec);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// modular header

alias j40__transform_id = int;
enum : j40__transform_id 
{
    J40__TR_RCT = 0, 
    J40__TR_PALETTE = 1, 
    J40__TR_SQUEEZE = 2
}

union j40__transform 
{
    j40__transform_id tr;
    static struct rct_t
    {
        j40__transform_id tr; // = J40__TR_RCT
        int begin_c, type;
    }
    rct_t rct;

    struct pal_t
    {
        j40__transform_id tr; // = J40__TR_PALETTE
        int begin_c, num_c, nb_colours, nb_deltas, d_pred;
    }
    pal_t pal;

    // this is nested in the bitstream, but flattened here.
    // nb_transforms get updated accordingly, but should be enough (the maximum is 80808)
    struct sq_t
    {
        j40__transform_id tr; // = J40__TR_SQUEEZE
        int implicit; // if true, no explicit parameters given in the bitstream
        int horizontal, in_place;
        int begin_c, num_c;
    }
    sq_t sq;
}

struct j40__wp_params
{ 
    byte p1 = 0;
    byte p2 = 0;
    byte[5] p3 = [0, 0, 0, 0, 0];
    byte[4] w  = [0, 0, 0, 0]; 
}

struct j40__modular // zero-initialized
{
    int use_global_tree = 0;
    j40__wp_params wp;
    int nb_transforms = 0;
    j40__transform *transform = null;
    j40__tree_node *tree = null; // owned only if use_global_tree is false
    j40__code_spec codespec;
    j40__code_st code;
    int num_channels = 0, 
        nb_meta_channels = 0;
    j40__plane* channel = null; // should use the same type, either i16 or i32
    int dist_mult = 0; // min(max(non-meta channel width), J40__MAX_DIST_MULT)
}

void j40__init_modular_common(j40__modular *m) 
{
    m.transform = null;
    m.tree = null;
    memset(&m.codespec, 0, j40__code_spec.sizeof);
    memset(&m.code, 0, j40__code_st.sizeof);
    m.code.spec = &m.codespec;
    m.channel = null;
}

j40_err j40__init_modular(j40__st *st, 
                          int num_channels, 
                          const(int)* w, 
                          const(int)* h, 
                          j40__modular *m) 
{
    int i;

    j40__init_modular_common(m);
    m.num_channels = num_channels;
    assert(num_channels > 0);

    m.channel = cast(j40__plane*) j40__calloc(cast(size_t) num_channels, j40__plane.sizeof);

    for (i = 0; i < num_channels; ++i) 
    {
        m.channel[i].width = w[i];
        m.channel[i].height = h[i];
        m.channel[i].hshift = m.channel[i].vshift = 0;
    }
J40__ON_ERROR:
    return st.err;
}

j40_err j40__init_modular_for_global(
    j40__st *st, int frame_is_modular, int frame_do_ycbcr,
    int frame_log_upsampling, const int *frame_ec_log_upsampling,
    int frame_width, int frame_height, j40__modular *m
) {
    j40__image_st *im = st.image;
    int i;

    j40__init_modular_common(m);
    m.num_channels = im.num_extra_channels;
    if (frame_is_modular) { // SPEC the condition is negated
        m.num_channels += (!frame_do_ycbcr && !im.xyb_encoded && im.cspace == J40__CS_GREY ? 1 : 3);
    }
    if (m.num_channels == 0) return 0;

    m.channel = cast(j40__plane*) j40__calloc(cast(size_t) m.num_channels, j40__plane.sizeof);

    for (i = 0; i < im.num_extra_channels; ++i) {
        int log_upsampling = (frame_ec_log_upsampling ? frame_ec_log_upsampling[i] : 0) + im.ec_info[i].dim_shift;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((log_upsampling >= frame_log_upsampling) == 0)) { j40__set_error(st, J40__4("usmp")); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((log_upsampling == 0) == 0)) { j40__set_error(st, J40__4("TODO: upsampling is not yet supported")); goto J40__ON_ERROR; } } while (0);
        m.channel[i].width = frame_width;
        m.channel[i].height = frame_height;
        m.channel[i].hshift = m.channel[i].vshift = 0;
    }
    for (; i < m.num_channels; ++i) {
        m.channel[i].width = frame_width;
        m.channel[i].height = frame_height;
        m.channel[i].hshift = m.channel[i].vshift = 0;
    }
    return 0;

J40__ON_ERROR:
    j40__free(m.channel);
    m.channel = null;
    return st.err;
}

j40_err j40__init_modular_for_pass_group(
    j40__st *st, int num_gm_channels, int gw, int gh,
    int minshift, int maxshift, const(j40__modular)* gm, j40__modular *m
) {
    int i, max_channels;

    j40__init_modular_common(m);
    m.num_channels = 0;
    max_channels = gm.num_channels - num_gm_channels;
    assert(max_channels >= 0);
    
    m.channel = cast(j40__plane*) j40__calloc(cast(size_t) max_channels, j40__plane.sizeof);


    for (i = num_gm_channels; i < gm.num_channels; ++i) {
        const(j40__plane)* gc = &gm.channel[i];
        j40__plane* c = &m.channel[m.num_channels];
        if (gc.hshift < 3 || gc.vshift < 3) {
            assert(gc.hshift >= 0 && gc.vshift >= 0);
            // TODO check minshift/maxshift!!!
            c.hshift = gc.hshift;
            c.vshift = gc.vshift;
            c.width = gw >> gc.hshift; // TODO is this correct? should be ceil?
            c.height = gh >> gc.vshift;
            ++m.num_channels;
        }
    }
    if (m.num_channels == 0) {
        j40__free(m.channel);
        m.channel = null;
    }
J40__ON_ERROR:
    return st.err;
}

void j40__combine_modular_from_pass_group(
    int num_gm_channels, int gy, int gx,
    int minshift, int maxshift, const j40__modular *gm, j40__modular *m
) {
    int gcidx, cidx, y, gx0, gy0;
    for (gcidx = num_gm_channels, cidx = 0; gcidx < gm.num_channels; ++gcidx) 
    {
        const(j40__plane)* gc = &gm.channel[gcidx];
        j40__plane* c = &m.channel[cidx];
        assert(gc.type == c.type);
        if (gc.hshift < 3 || gc.vshift < 3) {
            size_t pixel_size = cast(size_t) J40__PLANE_PIXEL_SIZE(gc);
            size_t gc_stride = cast(size_t) gc.stride_bytes, 
                    c_stride = cast(size_t) c.stride_bytes;
            // TODO check minshift/maxshift!!!
            assert(gc.hshift == c.hshift && gc.vshift == c.vshift);
            gx0 = gx >> gc.hshift;
            gy0 = gy >> gc.vshift;
            assert(gx0 + c.width <= gc.width && gy0 + c.height <= gc.height);
            for (y = 0; y < c.height; ++y) {
                memcpy(
                    cast(void*) (gc.pixels + gc_stride * cast(size_t) (gy0 + y) + pixel_size * cast(size_t) gx0),
                    cast(void*) (c.pixels + c_stride * cast(size_t) y),
                    pixel_size * cast(size_t) c.width);
            }
            ++cidx;
        }
    }
    assert(cidx == m.num_channels);
}

j40_err j40__modular_header(
    j40__st *st, j40__tree_node *global_tree, const j40__code_spec *global_codespec,
    j40__modular *m
) {
    j40__plane *channel = m.channel;
    int num_channels = m.num_channels, nb_meta_channels = 0;
    // note: channel_cap is the upper bound of # channels during inverse transform, and since
    // we don't shrink the channel list we don't ever need reallocation in j40__inverse_transform!
    int channel_cap = m.num_channels, transform_cap;
    int i, j;

    assert(num_channels > 0);

    m.use_global_tree = j40__u(st, 1);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((!m.use_global_tree || global_tree) == 0)) { j40__set_error(st, J40__4("mtre")); goto J40__ON_ERROR; } } while (0);

    { // WPHeader
        int default_wp = j40__u(st, 1);
        m.wp.p1 = default_wp ? 16 : cast(byte) j40__u(st, 5);
        m.wp.p2 = default_wp ? 10 : cast(byte) j40__u(st, 5);
        for (i = 0; i < 5; ++i) m.wp.p3[i] = default_wp ? 7 * (i < 3) : cast(byte) j40__u(st, 5);
        for (i = 0; i < 4; ++i) m.wp.w[i] = default_wp ? 12 + (i < 1) : cast(byte) j40__u(st, 4);
    }

    transform_cap = m.nb_transforms = j40__u32(st, 0, 0, 1, 0, 2, 4, 18, 8);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((m.nb_transforms <= st.limits.nb_transforms) == 0)) { j40__set_error(st, J40__4("xlim")); goto J40__ON_ERROR; } } while (0);
    
    m.transform = cast(j40__transform*) j40__malloc(cast(size_t) transform_cap, j40__transform.sizeof);

    for (i = 0; i < m.nb_transforms; ++i) {
        j40__transform *tr = &m.transform[i];
        int num_sq;

        tr.tr = cast(j40__transform_id) j40__u(st, 2);
        switch (tr.tr) {
        // RCT: [begin_c, begin_c+3) . [begin_c, begin_c+3)
        case J40__TR_RCT: {
            int begin_c = tr.rct.begin_c = j40__u32(st, 0, 3, 8, 6, 72, 10, 1096, 13);
            int type = tr.rct.type = j40__u32(st, 6, 0, 0, 2, 2, 4, 10, 6);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((type < 42) == 0)) { j40__set_error(st, J40__4("rctt")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((begin_c + 3 <= num_channels) == 0)) { j40__set_error(st, J40__4("rctc")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((begin_c >= nb_meta_channels || begin_c + 3 <= nb_meta_channels) == 0)) { j40__set_error(st, J40__4("rctc")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__plane_all_equal_sized(channel + begin_c, channel + begin_c + 3)) == 0)) { j40__set_error(st, J40__4("rtcd")); goto J40__ON_ERROR; } } while (0);
            break;
        }

        // Palette: [begin_c, end_c) . palette 0 (meta, nb_colours by num_c) + index begin_c+1
        case J40__TR_PALETTE: {
            j40__plane input;
            int begin_c = tr.pal.begin_c = j40__u32(st, 0, 3, 8, 6, 72, 10, 1096, 13);
            int num_c = tr.pal.num_c = j40__u32(st, 1, 0, 3, 0, 4, 0, 1, 13);
            int end_c = begin_c + num_c;
            int nb_colours = tr.pal.nb_colours = j40__u32(st, 0, 8, 256, 10, 1280, 12, 5376, 16);
            tr.pal.nb_deltas = j40__u32(st, 0, 0, 1, 8, 257, 10, 1281, 16);
            tr.pal.d_pred = j40__u(st, 4);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((tr.pal.d_pred < J40__NUM_PRED) == 0)) { j40__set_error(st, J40__4("palp")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((end_c <= num_channels) == 0)) { j40__set_error(st, J40__4("palc")); goto J40__ON_ERROR; } } while (0);
            if (begin_c < nb_meta_channels) { // num_c meta channels . 2 meta channels (palette + index)
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((end_c <= nb_meta_channels) == 0)) { j40__set_error(st, J40__4("palc")); goto J40__ON_ERROR; } } while (0);
                nb_meta_channels += 2 - num_c;
            } else { // num_c color channels . 1 meta channel (palette) + 1 color channel (index)
                nb_meta_channels += 1;
            }
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__plane_all_equal_sized(channel + begin_c, channel + end_c)) == 0)) { j40__set_error(st, J40__4("pald")); goto J40__ON_ERROR; } } while (0);
            // inverse palette transform always requires one more channel slot

            channel = cast(j40__plane*) j40__realloc32(st, channel, j40__plane.sizeof, num_channels + 1, &channel_cap);
            
            input = channel[begin_c];
            memmove(channel + 1, channel, (*channel).sizeof * cast(size_t) begin_c);
            memmove(channel + begin_c + 2, channel + end_c, (*channel).sizeof * cast(size_t) (num_channels - end_c));
            channel[0].width = nb_colours;
            channel[0].height = num_c;
            channel[0].hshift = 0; // SPEC missing
            channel[0].vshift = -1;
            channel[begin_c + 1] = input;
            num_channels += 2 - num_c;
            break;
        }

        // Squeeze: 
        case J40__TR_SQUEEZE: {
            num_sq = j40__u32(st, 0, 0, 1, 4, 9, 6, 41, 8);
            if (num_sq == 0) {
                tr.sq.implicit = 1;
            } else {

                m.transform = cast(j40__transform*) j40__realloc32(st, m.transform, j40__transform.sizeof, m.nb_transforms + num_sq - 1, &transform_cap);
                
                for (j = 0; j < num_sq; ++j) 
                {
                    tr = &m.transform[i + j];
                    tr.sq.tr = J40__TR_SQUEEZE;
                    tr.sq.implicit = 0;
                    tr.sq.horizontal = j40__u(st, 1);
                    tr.sq.in_place = j40__u(st, 1);
                    tr.sq.begin_c = j40__u32(st, 0, 3, 8, 6, 72, 10, 1096, 13);
                    tr.sq.num_c = j40__u32(st, 1, 0, 2, 0, 3, 0, 4, 4);
                }
                i += num_sq - 1;
                m.nb_transforms += num_sq - 1;
            }
            j40__set_error(st, J40__4("TODO: squeeze channel effects")); 
            goto J40__ON_ERROR;
        }

        default: do { j40__set_error(st, J40__4("xfm?")); goto J40__ON_ERROR; } while (0);
        }
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
    }

    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((num_channels <= st.limits.nb_channels_tr) == 0)) { j40__set_error(st, J40__4("xlim")); goto J40__ON_ERROR; } } while (0);

    if (m.use_global_tree) 
    {
        m.tree = global_tree;
        memcpy(&m.codespec, global_codespec, j40__code_spec.sizeof);
    } 
    else 
    {
        int max_tree_size = 1024;
        for (i = 0; i < num_channels; ++i) {
            max_tree_size = j40__clamp_add32(max_tree_size, j40__clamp_mul32(channel[i].width, channel[i].height));
        }
        max_tree_size = j40__min32(1 << 20, max_tree_size);
        do { if (J40_UNLIKELY(j40__tree(st, max_tree_size, &m.tree, &m.codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
    j40__init_code(&m.code, &m.codespec);

    m.channel = channel;
    m.num_channels = num_channels;
    m.nb_meta_channels = nb_meta_channels;
    m.dist_mult = 0;
    for (i = nb_meta_channels; i < num_channels; ++i) {
        m.dist_mult = j40__max32(m.dist_mult, channel[i].width);
    }
    m.dist_mult = j40__min32(m.dist_mult, J40__MAX_DIST_MULT);
    return 0;

J40__ON_ERROR:
    j40__free(channel);
    j40__free(m.transform);
    if (!m.use_global_tree) {
        j40__free(m.tree);
        j40__free_code_spec(&m.codespec);
    }
    m.num_channels = 0;
    m.channel = null;
    m.transform = null;
    m.tree = null;
    memset(&m.codespec, 0, j40__code_spec.sizeof);
    return st.err;
}

j40_err j40__allocate_modular(j40__st *st, j40__modular *m) 
{
    ubyte pixel_type = cast(ubyte) (st.image.modular_16bit_buffers ? J40__PLANE_I16 : J40__PLANE_I32);
    int i;
    for (i = 0; i < m.num_channels; ++i) {
        j40__plane *c = &m.channel[i];
        if (c.width > 0 && c.height > 0) {
            do { if (J40_UNLIKELY(j40__init_plane(st, pixel_type, c.width, c.height, J40__PLANE_FORCE_PAD, c))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        } else { // possible when, for example, palette with only synthetic colors (nb_colours == 0)
            j40__init_empty_plane(c);
        }
    }
J40__ON_ERROR:
    return st.err;
}

void j40__free_modular(j40__modular *m) 
{
    int i;
    j40__free_code(&m.code);
    if (!m.use_global_tree) {
        j40__free(m.tree);
        j40__free_code_spec(&m.codespec);
    }
    if (m.channel) {
        for (i = 0; i < m.num_channels; ++i) j40__free_plane(&m.channel[i]);
        j40__free(m.channel);
        m.channel = null;
    }
    j40__free(m.transform);
    m.use_global_tree = 0;
    m.tree = null;
    memset(&m.codespec, 0, j40__code_spec.sizeof);
    m.transform = null;
    m.num_channels = 0;
}

////////////////////////////////////////////////////////////////////////////////
// modular prediction

static immutable int[64] J40__24DIVP1 = 
[   // [i] = floor(2^24 / (i+1))
    0x1000000, 0x800000, 0x555555, 0x400000, 0x333333, 0x2aaaaa, 0x249249, 0x200000,
    0x1c71c7, 0x199999, 0x1745d1, 0x155555, 0x13b13b, 0x124924, 0x111111, 0x100000,
    0xf0f0f, 0xe38e3, 0xd7943, 0xccccc, 0xc30c3, 0xba2e8, 0xb2164, 0xaaaaa,
    0xa3d70, 0x9d89d, 0x97b42, 0x92492, 0x8d3dc, 0x88888, 0x84210, 0x80000,
    0x7c1f0, 0x78787, 0x75075, 0x71c71, 0x6eb3e, 0x6bca1, 0x69069, 0x66666,
    0x63e70, 0x61861, 0x5f417, 0x5d174, 0x5b05b, 0x590b2, 0x57262, 0x55555,
    0x53978, 0x51eb8, 0x50505, 0x4ec4e, 0x4d487, 0x4bda1, 0x4a790, 0x49249,
    0x47dc1, 0x469ee, 0x456c7, 0x44444, 0x4325c, 0x42108, 0x41041, 0x40000,
];

// ----------------------------------------
// recursion for modular buffer sizes (16/32)
enum int J40__RECURSING = 200;


// note: in those template, P can be only 16 or 32

template j40__intP(int P)
{
    static if (P == 16)
        alias j40__intP = short;
    else
        alias j40__intP = int;
}


template j40__int2P(int P)
{
    static if (P == 16)
        alias j40__int2P = int;
    else
        alias j40__int2P = long;
}

template j40__uint2P(int P)
{
    static if (P == 16)
        alias j40__uint2P = uint;
    else
        alias j40__uint2P = ulong;
}

template j40__min2P(int P)
{
    static if (P == 16)
        alias j40__min2P = j40__min32;
    else
        alias j40__min2P = j40__min64;
}

template j40__max2P(int P)
{
    static if (P == 16)
        alias j40__max2P = j40__max32;
    else
        alias j40__max2P = j40__max64;
}

template J40__PIXELS(int P)
{
    static if (P == 16)
        alias J40__PIXELS = J40__I16_PIXELS;
    else
        alias J40__PIXELS = J40__I32_PIXELS;
}

struct j40__wp2P(int P)
{
    int width = 0;
    j40__wp_params params;
    j40__int2P!P[5]* errors = null;
    j40__int2P!P[5] pred = [0, 0, 0, 0, 0]; // [0..3] = sub-predictions, [4] = final prediction
    j40__int2P!P trueerrw = 0, 
                 trueerrn = 0, 
                 trueerrnw = 0, 
                 trueerrne  =0;
}

template J40__PLANE_I(int P)
{
    static if (P == 16)
        alias J40__PLANE_I = J40__PLANE_I16;
    else
        alias J40__PLANE_I = J40__PLANE_I32;
}

struct j40__neighborsP(int P)
{ 
    static if (P == 16)
        short w, n, nw, ne, nn, nee, ww, nww; 
    else
        int w, n, nw, ne, nn, nee, ww, nww; 
}

j40__neighborsP!P j40__init_neighbors(int P)(const j40__plane *plane, int x, int y) 
{
    j40__neighborsP!P p;
    const j40__intP!P *pixels = J40__PIXELS!P(plane, y);
    int width = plane.width, stride = J40__PLANE_STRIDE(plane);

    /*            NN
     *             |
     *             v
     * NWW  NW   _ N <- NE <- NEE
     *  |    |   /|
     *  v    v |/ 
     * WW . W  `  C
     *
     * A . B means that if A doesn't exist B is used instead.
     * if the pixel at the end of this chain doesn't exist as well, 0 is used.
     */
    p.w = x > 0 ? pixels[x - 1] : y > 0 ? pixels[x - stride] : 0;
    p.n = y > 0 ? pixels[x - stride] : p.w;
    p.nw = x > 0 && y > 0 ? pixels[(x - 1) - stride] : p.w;
    p.ne = x + 1 < width && y > 0 ? pixels[(x + 1) - stride] : p.n;
    p.nn = y > 1 ? pixels[x - 2 * stride] : p.n;
    p.nee = x + 2 < width && y > 0 ? pixels[(x + 2) - stride] : p.ne;
    p.ww = x > 1 ? pixels[x - 2] : p.w;
    p.nww = x > 1 && y > 0 ? pixels[(x - 2) - stride] : p.ww;
    return p;
}

j40__int2P!P j40__gradient2P(int P)(j40__int2P!P w, j40__int2P!P n, j40__int2P!P nw) 
{
    j40__int2P!P lo = j40__min2P!P(w, n), 
                 hi = j40__max2P!P(w, n);
    return j40__min2P!P(j40__max2P!P(lo, w + n - nw), hi);
}

j40_err j40__init_wp(int P)(j40__st *st, 
                            j40__wp_params params, 
                            int width, 
                            j40__wp2P!P *wp) 
{
    alias j40__i2Px5 = j40__int2P!P[5];
    int i;
    assert(width > 0);
    wp.width = width;
    wp.params = params;
    
    wp.errors = cast(j40__i2Px5*) j40__malloc(cast(size_t) width * 2, j40__i2Px5.sizeof);

    for (i = 0; i < 5; ++i) 
        wp.pred[i] = 0;
    wp.trueerrw = wp.trueerrn = wp.trueerrnw = wp.trueerrne = 0;
J40__ON_ERROR:
    return st.err;
}

// also works when wp is zero-initialized (in which case does nothing)
void j40__wp_before_predict_internal(int P)(j40__wp2P!P* wp, int x, int y,
    j40__intP!P pw, j40__intP!P pn, j40__intP!P pnw, j40__intP!P pne, j40__intP!P pnn) 
{
    alias int2P_t = j40__int2P!P;
    alias uint2P_t = j40__uint2P!P;

    static immutable int2P_t[4] ZERO = [0, 0, 0, 0];

    int2P_t[5]* err, nerr;
    int2P_t[4] w;
    int2P_t wsum, sum;
    int logw, i;
    const(int2P_t)* errw, errn, errnw, errne, errww, errw2;

    if (!wp.errors) return;

    err = wp.errors + (y & 1 ? wp.width : 0);
    nerr = wp.errors + (y & 1 ? 0 : wp.width);

    // SPEC edge cases are handled differently from the spec, in particular some pixels are
    // added twice to err_sum and requires a special care (errw2 below)
    errw = x > 0 ? err[x - 1].ptr : ZERO.ptr;
    errn = y > 0 ? nerr[x].ptr : ZERO.ptr;
    errnw = x > 0 && y > 0 ? nerr[x - 1].ptr : errn;
    errne = x + 1 < wp.width && y > 0 ? nerr[x + 1].ptr : errn;
    errww = x > 1 ? err[x - 2].ptr : ZERO.ptr;
    errw2 = x + 1 < wp.width ? ZERO.ptr : errw;

    // SPEC again, edge cases are handled differently
    wp.trueerrw = x > 0 ? err[x - 1][4] : 0;
    wp.trueerrn = y > 0 ? nerr[x][4] : 0;
    wp.trueerrnw = x > 0 && y > 0 ? nerr[x - 1][4] : wp.trueerrn;
    wp.trueerrne = x + 1 < wp.width && y > 0 ? nerr[x + 1][4] : wp.trueerrn;

    // (expr << 3) is used throughout wp, but it's an UB when expr is negative
    wp.pred[0] = (pw + pne - pn) * 8;
    wp.pred[1] = pn * 8 - (((wp.trueerrw + wp.trueerrn + wp.trueerrne) * wp.params.p1) >> 5);
    wp.pred[2] = pw * 8 - (((wp.trueerrw + wp.trueerrn + wp.trueerrnw) * wp.params.p2) >> 5);
    wp.pred[3] = pn * 8 - // SPEC negated (was `+`)
        ((wp.trueerrnw * wp.params.p3[0] + wp.trueerrn * wp.params.p3[1] +
          wp.trueerrne * wp.params.p3[2] + (pnn - pn) * 8 * wp.params.p3[3] +
          (pnw - pw) * 8 * wp.params.p3[4]) >> 5);
    for (i = 0; i < 4; ++i) {
        int2P_t errsum = errn[i] + errw[i] + errnw[i] + errww[i] + errne[i] + errw2[i];
        int shift = j40__max32(j40__floor_lg2P!P(cast(uint2P_t) errsum + 1) - 5, 0);
        // SPEC missing the final `>> shift`
        w[i] = cast(int2P_t) (4 + (cast(long) wp.params.w[i] * J40__24DIVP1[cast(size_t)(errsum >> shift)] >> shift));
    }
    logw = j40__floor_lg2P!P(cast(uint2P_t) (w[0] + w[1] + w[2] + w[3])) - 4;
    wsum = sum = 0;
    for (i = 0; i < 4; ++i) {
        wsum += w[i] >>= logw;
        sum += wp.pred[i] * w[i];
    }
    // SPEC missing `- 1` before scaling
    wp.pred[4] = cast(int2P_t) ((cast(long) sum + (wsum >> 1) - 1) * J40__24DIVP1[cast(size_t)(wsum - 1)] >> 24);
    if (((wp.trueerrn ^ wp.trueerrw) | (wp.trueerrn ^ wp.trueerrnw)) <= 0) {
        int2P_t lo = j40__min2P!P(pw, j40__min2P!P(pn, pne)) * 8; // SPEC missing shifts
        int2P_t hi = j40__max2P!P(pw, j40__max2P!P(pn, pne)) * 8;
        wp.pred[4] = j40__min2P!P(j40__max2P!P(lo, wp.pred[4]), hi);
    }
}

void j40__wp_before_predict2P(int P)(j40__wp2P!P *wp, int x, int y, j40__neighborsP!P *p) 
{
    j40__wp_before_predict_internal!P(wp, x, y, p.w, p.n, p.nw, p.ne, p.nn);
}

j40__int2P!P j40__predict2P(int P)(
    j40__st *st, int pred, const j40__wp2P!P *wp, const(j40__neighborsP!P)* p
) 
{
    switch (pred) 
    {
    case 0: return 0;
    case 1: return p.w;
    case 2: return p.n;
    case 3: return (p.w + p.n) / 2;
    case 4: return j40__abs2P!P(p.n - p.nw) < j40__abs2P!P(p.w - p.nw) ? p.w : p.n;
    case 5: return j40__gradient2P!P(p.w, p.n, p.nw);
    case 6: return (wp.pred[4] + 3) >> 3;
    case 7: return p.ne;
    case 8: return p.nw;
    case 9: return p.ww;
    case 10: return (p.w + p.nw) / 2;
    case 11: return (p.n + p.nw) / 2;
    case 12: return (p.n + p.ne) / 2;
    case 13: return (6 * p.n - 2 * p.nn + 7 * p.w + p.ww + p.nee + 3 * p.ne + 8) / 16;
    default: 
        j40__set_error(st, J40__4("pred"));
        return 0;
    }
}

// also works when wp is zero-initialized (in which case does nothing)
void j40__wp_after_predict2P(int P)(j40__wp2P!P *wp, int x, int y, j40__int2P!P val) 
{
    if (wp.errors) 
    {
        j40__int2P!P *err = wp.errors[(y & 1 ? wp.width : 0) + x].ptr;
        int i;
        // SPEC approximated differently from the spec
        for (i = 0; i < 4; ++i)
            err[i] = (j40__abs2P!P(wp.pred[i] - val * 8) + 3) >> 3;
        err[4] = wp.pred[4] - val * 8; // SPEC this is a *signed* difference
    }
}

// also works when wp is zero-initialized (in which case does nothing)
void j40__reset_wp2P(int P)(j40__wp2P!P* wp) 
{
    int i;
    if (wp.errors) memset(wp.errors, 0, cast(size_t) wp.width * 2 * (j40__int2P!P[5]).sizeof);
    for (i = 0; i < 5; ++i) 
        wp.pred[i] = 0;
    wp.trueerrw = wp.trueerrn = wp.trueerrnw = wp.trueerrne = 0;
}

void j40__free_wp2P(int P)(j40__wp2P!P *wp) 
{
    j40__free(wp.errors);
    wp.errors = null;
    wp.width = 0;
}

j40_err j40__modular_channelP(int P)(
    j40__st *st, j40__modular *m, int cidx, long sidx
) 
{
    alias intP_t = j40__intP!P;
    alias int2P_t = j40__int2P!P;

    j40__plane *c = &m.channel[cidx];
    int width = c.width, height = c.height;
    int y, x, i;
    int nrefcmap;
    int*refcmap = null; // refcmap[i] is a channel index for properties (16..19)+4*i
    j40__wp2P!P wp; // zero-initialized

    assert(m.tree); // caller should set this to the global tree if not given
    assert(c.type == J40__PLANE_I!P);

    {
        // determine whether to use weighted predictor (expensive)
        int lasttree = 0, use_wp = 0;
        for (i = 0; i <= lasttree && !use_wp; ++i) {
            if (m.tree[i].branch.prop < 0) {
                use_wp |= ~m.tree[i].branch.prop == 15;
                lasttree = j40__max32(lasttree,
                    i + j40__max32(m.tree[i].branch.leftoff, m.tree[i].branch.rightoff));
            } else {
                use_wp |= m.tree[i].leaf.predictor == 6;
            }
        }
        if (use_wp) 
        {
            if (J40_UNLIKELY(j40__init_wp!P(st, m.wp, width, &wp))) 
            { 
                assert(st.err); 
                goto J40__ON_ERROR; 
            }
        }
    }

    // compute indices for additional "previous channel" properties
    // SPEC incompatible channels are skipped and never result in unusable but numbered properties
    refcmap = cast(int*) j40__malloc(cast(size_t) cidx, int.sizeof);

    nrefcmap = 0;
    for (i = cidx - 1; i >= 0; --i) 
    {
        j40__plane *refc = &m.channel[i];
        if (c.width != refc.width || c.height != refc.height) continue;
        if (c.hshift != refc.hshift || c.vshift != refc.vshift) continue;
        refcmap[nrefcmap++] = i;
    }

    for (y = 0; y < height; ++y) {
        intP_t *outpixels = J40__PIXELS!P(c, y);
        for (x = 0; x < width; ++x) {
            j40__tree_node *n = m.tree;
            j40__neighborsP!P p = j40__init_neighbors!P(c, x, y);
            int2P_t val;

            // wp should be calculated before any property testing due to max_error (property 15)
            j40__wp_before_predict2P!P(&wp, x, y, &p);

            while (n.branch.prop < 0) {
                int refcidx;
                j40__plane *refc;

                switch (~n.branch.prop) {
                case 0: val = cidx; break;
                case 1: val = cast(int2P_t) sidx; break; // TODO check overflow
                case 2: val = y; break;
                case 3: val = x; break;
                case 4: val = j40__abs2P!P(p.n); break;
                case 5: val = j40__abs2P!P(p.w); break;
                case 6: val = p.n; break;
                case 7: val = p.w; break;
                case 8: val = x > 0 ? p.w - (p.ww + p.nw - p.nww) : p.w; break;
                case 9: val = p.w + p.n - p.nw; break;
                case 10: val = p.w - p.nw; break;
                case 11: val = p.nw - p.n; break;
                case 12: val = p.n - p.ne; break;
                case 13: val = p.n - p.nn; break;
                case 14: val = p.w - p.ww; break;
                case 15: // requires use_wp; otherwise will be 0
                    val = wp.trueerrw;
                    if (j40__abs2P!P(val) < j40__abs2P!P(wp.trueerrn)) val = wp.trueerrn;
                    if (j40__abs2P!P(val) < j40__abs2P!P(wp.trueerrnw)) val = wp.trueerrnw;
                    if (j40__abs2P!P(val) < j40__abs2P!P(wp.trueerrne)) val = wp.trueerrne;
                    break;
                default:
                    refcidx = (~n.branch.prop - 16) / 4;
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((refcidx < nrefcmap) == 0)) { j40__set_error(st, J40__4("trec")); goto J40__ON_ERROR; } } while (0);
                    refc = &m.channel[refcmap[refcidx]];
                    assert(c.width == refc.width && c.height == refc.height);
                    val = J40__PIXELS!P(refc, y)[x]; // rC
                    if (~n.branch.prop & 2) {
                        int2P_t rw = x > 0 ? J40__PIXELS!P(refc, y)[x - 1] : 0;
                        int2P_t rn = y > 0 ? J40__PIXELS!P(refc, y - 1)[x] : rw;
                        int2P_t rnw = x > 0 && y > 0 ? J40__PIXELS!P(refc, y - 1)[x - 1] : rw;
                        val -= j40__gradient2P!P(rw, rn, rnw);
                    }
                    if (~n.branch.prop & 1) val = j40__abs2P!P(val);
                    break;
                }
                n += val > n.branch.value ? n.branch.leftoff : n.branch.rightoff;
            }

            val = j40__code(st, n.leaf.ctx, m.dist_mult, &m.code);
            // TODO can overflow at any operator and the bound is incorrect anyway
            val = j40__unpack_signed(cast(int) val) * n.leaf.multiplier + n.leaf.offset;
            val += j40__predict2P!P(st, n.leaf.predictor, &wp, &p);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((INT16_MIN <= val && val <= INT16_MAX) == 0)) { j40__set_error(st, J40__4("povf")); goto J40__ON_ERROR; } } while (0);
            outpixels[x] = cast(intP_t) val;
            j40__wp_after_predict2P!P(&wp, x, y, val);
        }
    }

    j40__free_wp2P!P(&wp);
    j40__free(refcmap);
    return 0;

J40__ON_ERROR:
    j40__free_wp2P(&wp);
    j40__free(refcmap);
    j40__free_plane(c);
    return st.err;
}

j40_err j40__modular_channel(j40__st *st, j40__modular *m, int cidx, long sidx) 
{
    switch (m.channel[cidx].type) 
    {
        case J40__PLANE_I16: return j40__modular_channelP!16(st, m, cidx, sidx);
        case J40__PLANE_I32: return j40__modular_channelP!32(st, m, cidx, sidx);
        case J40__PLANE_EMPTY: return 0;
        default: J40__UNREACHABLE(); return 0;
    }
}

////////////////////////////////////////////////////////////////////////////////
// modular (inverse) transform

j40_err j40__inverse_transform(j40__st *st, j40__modular *m);


static immutable short[3][144] J40__PALETTE_DELTAS = 
[ 
    [0,0,0], [-0,-0,-0], [4,4,4], [-4,-4,-4], [11,0,0], [-11,-0,-0], [0,0,-13], [-0,-0,13], [0,-12,0], [-0,12,-0], [-10,-10,-10], [10,10,10],
    [-18,-18,-18], [18,18,18], [-27,-27,-27], [27,27,27], [-18,-18,0], [18,18,-0], [0,0,-32], [-0,-0,32], [-32,0,0], [32,-0,-0], [-37,-37,-37], [37,37,37],
    [0,-32,-32], [-0,32,32], [24,24,45], [-24,-24,-45], [50,50,50], [-50,-50,-50], [-45,-24,-24], [45,24,24], [-24,-45,-45], [24,45,45], [0,-24,-24], [-0,24,24],
    [-34,-34,0], [34,34,-0], [-24,0,-24], [24,-0,24], [-45,-45,-24], [45,45,24], [64,64,64], [-64,-64,-64], [-32,0,-32], [32,-0,32], [0,-32,0], [-0,32,-0],
    [-32,0,32], [32,-0,-32], [-24,-45,-24], [24,45,24], [45,24,45], [-45,-24,-45], [24,-24,-45], [-24,24,45], [-45,-24,24], [45,24,-24], [80,80,80], [-80,-80,-80],
    [64,0,0], [-64,-0,-0], [0,0,-64], [-0,-0,64], [0,-64,-64], [-0,64,64], [-24,-24,45], [24,24,-45], [96,96,96], [-96,-96,-96], [64,64,0], [-64,-64,-0],
    [45,-24,-24], [-45,24,24], [34,-34,0], [-34,34,-0], [112,112,112], [-112,-112,-112], [24,-45,-45], [-24,45,45], [45,45,-24], [-45,-45,24], [0,-32,32], [-0,32,-32],
    [24,-24,45], [-24,24,-45], [0,96,96], [-0,-96,-96], [45,-24,24], [-45,24,-24], [24,-45,-24], [-24,45,24], [-24,-45,24], [24,45,-24], [0,-64,0], [-0,64,-0],
    [96,0,0], [-96,-0,-0], [128,128,128], [-128,-128,-128], [64,0,64], [-64,-0,-64], [144,144,144], [-144,-144,-144], [96,96,0], [-96,-96,-0], [-36,-36,36], [36,36,-36],
    [45,-24,-45], [-45,24,45], [45,-45,-24], [-45,45,24], [0,0,-96], [-0,-0,96], [0,128,128], [-0,-128,-128], [0,96,0], [-0,-96,-0], [45,24,-45], [-45,-24,45],
    [-128,0,0], [128,-0,-0], [24,-45,24], [-24,45,-24], [-45,24,-45], [45,-24,45], [64,0,-64], [-64,-0,64], [64,-64,-64], [-64,64,64], [96,0,96], [-96,-0,-96],
    [45,-45,24], [-45,45,-24], [24,45,-45], [-24,-45,45], [64,64,-64], [-64,-64,64], [128,128,0], [-128,-128,-0], [0,0,-128], [-0,-0,128], [-24,45,-45], [24,-45,45],
];

void j40__inverse_rctP(int P)(j40__modular *m, const(j40__transform)* tr) 
{
    alias intP_t = j40__intP!P;
    alias int2P_t = j40__int2P!P;

    // SPEC permutation pseudocode is missing parentheses; better done with a LUT anyway
    static immutable ubyte[3][6] PERMUTATIONS = [[0,1,2],[1,2,0],[2,0,1],[0,2,1],[1,0,2],[2,1,0]];

    j40__plane[3] c;
    int x, y, i;

    assert(tr.tr == J40__TR_RCT);
    for (i = 0; i < 3; ++i) c[i] = m.channel[tr.rct.begin_c + i];
    assert(j40__plane_all_equal_sized(c[]));

    // it is possible that input planes are empty, in which case we do nothing (not even shuffling)
    if (c[0].type == J40__PLANE_EMPTY) 
    {
        assert(j40__plane_all_equal_typed(c[]) == J40__PLANE_EMPTY);
        return;
    } 
    else 
    {
        assert(j40__plane_all_equal_typed(c[]) == J40__PLANE_I!P);
    }

    int width = c[0].width;
    int height = c[0].height;


    // TODO detect overflow
    switch (tr.rct.type % 7) {
    case 0: break;
    case 1:
        for (y = 0; y < height; ++y) 
        {
            intP_t* pp0 = J40__PIXELS!P(&c[0], y), 
                    pp2 = J40__PIXELS!P(&c[2], y);
            for (x = 0; x < width; ++x) 
                pp2[x] = cast(intP_t) (pp2[x] + pp0[x]);
        }
        break;
    case 2:
        for (y = 0; y < height; ++y) {
            intP_t* pp0 = J40__PIXELS!P(&c[0], y), 
                    pp1 = J40__PIXELS!P(&c[1], y), 
                    pp2 = J40__PIXELS!P(&c[2], y);
            for (x = 0; x < width; ++x) 
                pp2[x] = cast(intP_t) (pp1[x] + pp0[x]);
        }
        break;
    case 3:
        for (y = 0; y < height; ++y) 
        {
            intP_t* pp0 = J40__PIXELS!P(&c[0], y), 
                    pp1 = J40__PIXELS!P(&c[1], y), 
                    pp2 = J40__PIXELS!P(&c[2], y);
            for (x = 0; x < width; ++x) 
            {
                pp1[x] = cast(intP_t) (pp1[x] + pp0[x]);
                pp2[x] = cast(intP_t) (pp2[x] + pp0[x]);
            }
        }
        break;
    case 4:
        for (y = 0; y < height; ++y) {
            intP_t* pp0 = J40__PIXELS!P(&c[0], y),
                    pp1 = J40__PIXELS!P(&c[1], y), 
                    pp2 = J40__PIXELS!P(&c[2], y);
            for (x = 0; x < width; ++x) 
                pp1[x] = cast(intP_t) (pp1[x] + j40__floor_avg!P(pp0[x], pp2[x]));
        }
        break;
    case 5:
        for (y = 0; y < height; ++y) 
        {
            intP_t* pp0 = J40__PIXELS!P(&c[0], y), 
                    pp1 = J40__PIXELS!P(&c[1], y), 
                    pp2 = J40__PIXELS!P(&c[2], y);
            for (x = 0; x < width; ++x) 
            {
                // TODO avoid int2P_t if possible
                pp1[x] = cast(intP_t) (cast(int2P_t) pp1[x] + pp0[x] + (pp2[x] >> 1));
                pp2[x] = cast(intP_t) (pp2[x] + pp0[x]);
            }
        }
        break;
    case 6: // YCgCo
        for (y = 0; y < height; ++y) 
        {
            intP_t* pp0 = J40__PIXELS!P(&c[0], y), 
                    pp1 = J40__PIXELS!P(&c[1], y), 
                    pp2 = J40__PIXELS!P(&c[2], y);
            for (x = 0; x < width; ++x) {
                // TODO avoid int2P_t if possible
                int2P_t tmp = cast(int2P_t) pp0[x] - (cast(int2P_t) pp2[x] >> 1);
                int2P_t p1 = cast(int2P_t) pp2[x] + tmp;
                int2P_t p2 = tmp - (cast(int2P_t) pp1[x] >> 1);
                pp0[x] = cast(intP_t) (p2 + pp1[x]);
                pp1[x] = cast(intP_t) p1;
                pp2[x] = cast(intP_t) p2;
            }
        }
        break;
    default: J40__UNREACHABLE();
    }

    for (i = 0; i < 3; ++i) {
        m.channel[tr.rct.begin_c + PERMUTATIONS[tr.rct.type / 7][i]] = c[i];
    }
}

j40_err j40__inverse_paletteP(int P)(j40__st *st, 
                                     j40__modular *m, 
                                     const(j40__transform)* tr) 
{
    alias intP_t = j40__intP!P;
    alias int2P_t = j40__int2P!P;

    // `first` is the index channel index; restored color channels will be at indices [first,last],
    // where the original index channel is relocated to the index `last` and then repurposed.
    // the palette meta channel 0 will be removed at the very end.
    int first = tr.pal.begin_c + 1, last = tr.pal.begin_c + tr.pal.num_c, bpp = st.image.bpp;
    int i, j, y, x;
    j40__plane *idxc;
    int width = m.channel[first].width, height = m.channel[first].height;
    int use_pred = tr.pal.nb_deltas > 0, use_wp = use_pred && tr.pal.d_pred == 6;
    j40__wp2P!P wp;

    assert(tr.tr == J40__TR_PALETTE);

    // since we never shrink m.channel, we know there is enough capacity for intermediate transform
    memmove(m.channel + last, m.channel + first, j40__plane.sizeof * cast(size_t) (m.num_channels - first));
    m.num_channels += last - first;
    idxc = &m.channel[last];

    for (i = first; i < last; ++i) m.channel[i].type = 0;
    if (idxc.type == J40__PLANE_EMPTY) {
        // index channel is empty; all resulting output channels would be empty
        for (i = first; i < last; ++i) j40__init_empty_plane(&m.channel[i]);
    } else {
        for (i = first; i < last; ++i) 
        {
            do { if (J40_UNLIKELY(j40__init_plane(st, J40__PLANE_I!P, width, height, 0, &m.channel[i]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
    }

    if (use_wp) 
    { 
        if (J40_UNLIKELY(j40__init_wp!P(st, m.wp, width, &wp))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        } 
    }

    for (i = 0; i < tr.pal.num_c; ++i) 
    {
        // palette channel can be also empty
        intP_t *palp = tr.pal.nb_colours > 0 ? J40__PIXELS!P(&m.channel[0], i) : null;
        j40__plane *c = &m.channel[first + i];
        for (y = 0; y < height; ++y) {
            // SPEC pseudocode accidentally overwrites the index channel
            intP_t *idxline = J40__PIXELS!P(idxc, y);
            intP_t *line = J40__PIXELS!P(c, y);
            for (x = 0; x < width; ++x) {
                intP_t idx = idxline[x], val;
                int is_delta = idx < tr.pal.nb_deltas;
                if (idx < 0) { // hard-coded delta for first 3 channels, otherwise 0
                    if (i < 3) {
                        idx = cast(intP_t) (~cast(int)idx % 143); // say no to 1's complement
                        val = J40__PALETTE_DELTAS[idx + 1][i];
                        if (bpp > 8) val =  cast(intP_t) (val << (j40__min32(bpp, 24) - 8));
                    } else {
                        val = 0;
                    }
                } else if (idx < tr.pal.nb_colours) {
                    val = palp[idx];
                } else { // synthesized from (idx - nb_colours)
                    idx = cast(intP_t) (idx - tr.pal.nb_colours);
                    if (idx < 64) { // idx == ..YX in base 4 . {(X+0.5)/4, (Y+0.5)/4, ...}
                        val = cast(intP_t) ((i < 3 ? idx >> (2 * i) : 0) * ((cast(int2P_t) 1 << bpp) - 1) / 4 +
                            (cast(int2P_t) 1 << j40__max32(0, bpp - 3)));
                    } else { // idx + 64 == ..ZYX in base 5 . {X/4, Y/4, Z/4, ...}
                        val = cast(intP_t) (idx - 64);
                        for (j = 0; j < i; ++j) val = cast(intP_t) (val / 5);
                        val = cast(intP_t) ((val % 5) * ((1 << bpp) - 1) / 4);
                    }
                }
                if (use_pred) {
                    j40__neighborsP!P p = j40__init_neighbors!P(c, x, y);
                    j40__wp_before_predict2P!P(&wp, x, y, &p);
                    // TODO handle overflow
                    if (is_delta) val = cast(intP_t) (val + j40__predict2P!P(st, tr.pal.d_pred, &wp, &p));
                    j40__wp_after_predict2P!P(&wp, x, y, val);
                }
                line[x] = val;
            }
        }
        j40__reset_wp2P!P(&wp);
    }

    j40__free_wp2P!P(&wp);
    j40__free_plane(&m.channel[0]);
    memmove(m.channel, m.channel + 1, (j40__plane).sizeof * cast(size_t) --m.num_channels);
    return 0;

J40__ON_ERROR:
    j40__free_wp2P!P(&wp);
    return st.err;
}

// ----------------------------------------

j40_err j40__inverse_transform(j40__st *st, j40__modular *m) 
{
    int i;

    if (m.num_channels == 0) return 0;

    switch (j40__plane_all_equal_typed_or_empty(m.channel, m.channel + m.num_channels)) 
    {
    case J40__PLANE_I16:
        for (i = m.nb_transforms - 1; i >= 0; --i) 
        {
            const j40__transform *tr = &m.transform[i];
            switch (tr.tr) 
            {
            case J40__TR_RCT: j40__inverse_rctP!16(m, tr); break;
            case J40__TR_PALETTE: 
                if (J40_UNLIKELY(j40__inverse_paletteP!16(st, m, tr))) 
                { 
                    assert(st.err); 
                    goto J40__ON_ERROR; 
                }
                break;
            case J40__TR_SQUEEZE: 
                j40__set_error(st, J40__4("TODO: squeeze inverse transformation")); 
                goto J40__ON_ERROR;
            default: J40__UNREACHABLE();
            }
        }
        break;

    case J40__PLANE_I32:
        for (i = m.nb_transforms - 1; i >= 0; --i) 
        {
            const j40__transform *tr = &m.transform[i];
            switch (tr.tr) 
            {
            case J40__TR_RCT: j40__inverse_rctP!32(m, tr); break;
            case J40__TR_PALETTE: 
                if (J40_UNLIKELY(j40__inverse_paletteP!32(st, m, tr))) 
                { 
                    assert(st.err); 
                    goto J40__ON_ERROR;
                }
                break;
            case J40__TR_SQUEEZE: 
                j40__set_error(st, J40__4("TODO: squeeze inverse transformation")); 
                goto J40__ON_ERROR;
            
            default: J40__UNREACHABLE();
            }
        }
        break;

    default: // while *some* channels can be empty, it is impossible that all channels are empty
        J40__UNREACHABLE();
    }

J40__ON_ERROR:
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// dequantization matrix and coefficient orders

enum 
{
    J40__NUM_DCT_SELECT = 27, // the number of all possible varblock types (DctSelect)
    J40__NUM_DCT_PARAMS = 17, // the number of parameters, some shared by multiple DctSelects
    J40__NUM_ORDERS = 13, // the number of distinct varblock dimensions & orders, after transposition
}

alias j40__dq_matrix_mode = int;
enum : j40__dq_matrix_mode   // the number of params per channel follows:
{   
    J40__DQ_ENC_LIBRARY = 0, // 0
    J40__DQ_ENC_HORNUSS = 1, // 3 (params)
    J40__DQ_ENC_DCT2 = 2, // 6 (params)
    J40__DQ_ENC_DCT4 = 3, // 2 (params) + n (dct_params)
    // TODO DCT4x8 uses an undefined name "parameters" (should be "params")
    J40__DQ_ENC_DCT4X8 = 4, // 1 (params) + n (dct_params)
    J40__DQ_ENC_AFV = 5, // 9 (params) + n (dct_params) + m (dct4x4_params)
    J40__DQ_ENC_DCT = 6, // n (params)
    // all other modes eventually decode to:
    J40__DQ_ENC_RAW = 7, // n rows * m columns, with the top-left 1/8 by 1/8 unused
};

struct j40__dq_matrix 
{
    j40__dq_matrix_mode mode;
    short n, m;
    j40_f32x4 *params; // the last element per each row is unused
}

struct j40__dct_select
{ 
    byte log_rows, log_columns, param_idx, order_idx; 
}

static immutable j40__dct_select[J40__NUM_DCT_SELECT] J40__DCT_SELECT = 
[
    // hereafter DCTnm refers to DCT(2^n)x(2^m) in the spec
    /*DCT33*/ j40__dct_select(3, 3, 0, 0), /*Hornuss*/ j40__dct_select(3, 3, 1, 1), /*DCT11*/ j40__dct_select(3, 3, 2, 1), /*DCT22*/ j40__dct_select(3, 3, 3, 1),
    /*DCT44*/ j40__dct_select(4, 4, 4, 2), /*DCT55*/ j40__dct_select(5, 5, 5, 3), /*DCT43*/ j40__dct_select(4, 3, 6, 4), /*DCT34*/ j40__dct_select(3, 4, 6, 4),
    /*DCT53*/ j40__dct_select(5, 3, 7, 5), /*DCT35*/ j40__dct_select(3, 5, 7, 5), /*DCT54*/ j40__dct_select(5, 4, 8, 6), /*DCT45*/ j40__dct_select(4, 5, 8, 6),
    /*DCT23*/ j40__dct_select(3, 3, 9, 1), /*DCT32*/ j40__dct_select(3, 3, 9, 1), /*AFV0*/ j40__dct_select(3, 3, 10, 1), /*AFV1*/ j40__dct_select(3, 3, 10, 1),
    /*AFV2*/ j40__dct_select(3, 3, 10, 1), /*AFV3*/ j40__dct_select(3, 3, 10, 1), /*DCT66*/ j40__dct_select(6, 6, 11, 7), /*DCT65*/ j40__dct_select(6, 5, 12, 8),
    /*DCT56*/ j40__dct_select(5, 6, 12, 8), /*DCT77*/ j40__dct_select(7, 7, 13, 9), /*DCT76*/ j40__dct_select(7, 6, 14, 10), /*DCT67*/ j40__dct_select(6, 7, 14, 10),
    /*DCT88*/ j40__dct_select(8, 8, 15, 11), /*DCT87*/ j40__dct_select(8, 7, 16, 12), /*DCT78*/ j40__dct_select(7, 8, 16, 12),
];

struct j40__dct_params 
{
    byte log_rows, log_columns, def_offset, def_mode, def_n, def_m;
} 

static immutable j40__dct_params[J40__NUM_DCT_PARAMS] J40__DCT_PARAMS = 
[
    /*DCT33*/ j40__dct_params(3, 3, 0, J40__DQ_ENC_DCT, 6, 0), /*Hornuss*/ j40__dct_params(3, 3, 6, J40__DQ_ENC_HORNUSS, 0, 0),
    /*DCT11*/ j40__dct_params(3, 3, 9, J40__DQ_ENC_DCT2, 0, 0), /*DCT22*/ j40__dct_params(3, 3, 15, J40__DQ_ENC_DCT4, 4, 0),
    /*DCT44*/ j40__dct_params(4, 4, 21, J40__DQ_ENC_DCT, 7, 0), /*DCT55*/ j40__dct_params(5, 5, 28, J40__DQ_ENC_DCT, 8, 0),
    /*DCT34*/ j40__dct_params(3, 4, 36, J40__DQ_ENC_DCT, 7, 0), /*DCT35*/ j40__dct_params(3, 5, 43, J40__DQ_ENC_DCT, 8, 0),
    /*DCT45*/ j40__dct_params(4, 5, 51, J40__DQ_ENC_DCT, 8, 0), /*DCT23*/ j40__dct_params(3, 3, 59, J40__DQ_ENC_DCT4X8, 4, 0),
    /*AFV*/ j40__dct_params(3, 3, 64, J40__DQ_ENC_AFV, 4, 4), /*DCT66*/ j40__dct_params(6, 6, 81, J40__DQ_ENC_DCT, 8, 0),
    /*DCT56*/ j40__dct_params(5, 6, 89, J40__DQ_ENC_DCT, 8, 0), /*DCT77*/ j40__dct_params(7, 7, 97, J40__DQ_ENC_DCT, 8, 0),
    /*DCT67*/ j40__dct_params(6, 7, 105, J40__DQ_ENC_DCT, 8, 0), /*DCT88*/ j40__dct_params(8, 8, 113, J40__DQ_ENC_DCT, 8, 0),
    /*DCT78*/ j40__dct_params(7, 8, 121, J40__DQ_ENC_DCT, 8, 0),
];

static immutable float[4][129] J40__LIBRARY_DCT_PARAMS = 
[    
    [3150.0f, 560.0f, 512.0f], [0.0f, 0.0f, -2.0f], [-0.4f, -0.3f, -1.0f],
    [-0.4f, -0.3f, 0.0f], [-0.4f, -0.3f, -1.0f], [-2.0f, -0.3f, -2.0f],

    [280.0f, 60.0f, 18.0f], [3160.0f, 864.0f, 200.0f], [3160.0f, 864.0f, 200.0f],

    [3840.0f, 960.0f, 640.0f], [2560.0f, 640.0f, 320.0f], [1280.0f, 320.0f, 128.0f],
    [640.0f, 180.0f, 64.0f], [480.0f, 140.0f, 32.0f], [300.0f, 120.0f, 16.0f],

    [1.0f, 1.0f, 1.0f], [1.0f, 1.0f, 1.0f], [2200.0f, 392.0f, 112.0f], [0.0f, 0.0f, -0.25f], [0.0f, 0.0f, -0.25f], [0.0f, 0.0f, -0.5f],

    [8996.8725711814115328f, 3191.48366296844234752f, 1157.50408145487200256f],
    [-1.3000777393353804f, -0.67424582104194355f, -2.0531423165804414f],
    [-0.49424529824571225f, -0.80745813428471001f, -1.4f],
    [-0.439093774457103443f, -0.44925837484843441f, -0.50687130033378396f],
    [-0.6350101832695744f, -0.35865440981033403f, -0.42708730624733904f],
    [-0.90177264050827612f, -0.31322389111877305f, -1.4856834539296244f],
    [-1.6162099239887414f, -0.37615025315725483f, -4.9209142884401604f],

    [15718.40830982518931456f, 7305.7636810695983104f, 3803.53173721215041536f],
    [-1.025f, -0.8041958212306401f, -3.060733579805728f],
    [-0.98f, -0.7633036457487539f, -2.0413270132490346f],
    [-0.9012f, -0.55660379990111464f, -2.0235650159727417f],
    [-0.4f, -0.49785304658857626f, -0.5495389509954993f],
    [-0.48819395464f, -0.43699592683512467f, -0.4f],
    [-0.421064f, -0.40180866526242109f, -0.4f],
    [-0.27f, -0.27321683125358037f, -0.3f],

    [7240.7734393502f, 1448.15468787004f, 506.854140754517f],
    [-0.7f, -0.5f, -1.4f], [-0.7f, -0.5f, -0.2f], [-0.2f, -0.5f, -0.5f],
    [-0.2f, -0.2f, -0.5f], [-0.2f, -0.2f, -1.5f], [-0.5f, -0.2f, -3.6f],

    [16283.2494710648897f, 5089.15750884921511936f, 3397.77603275308720128f],
    [-1.7812845336559429f, -0.320049391452786891f, -0.321327362693153371f],
    [-1.6309059012653515f, -0.35362849922161446f, -0.34507619223117997f],
    [-1.0382179034313539f, -0.30340000000000003f, -0.70340000000000003f],
    [-0.85f, -0.61f, -0.9f], [-0.7f, -0.5f, -1.0f], [-0.9f, -0.5f, -1.0f],
    [-1.2360638576849587f, -0.6f, -1.1754605576265209f],

    [13844.97076442300573f, 4798.964084220744293f, 1807.236946760964614f],
    [-0.97113799999999995f, -0.61125308982767057f, -1.2f],
    [-0.658f, -0.83770786552491361f, -1.2f], [-0.42026f, -0.79014862079498627f, -0.7f],
    [-0.22712f, -0.2692727459704829f, -0.7f], [-0.2206f, -0.38272769465388551f, -0.7f],
    [-0.226f, -0.22924222653091453f, -0.4f], [-0.6f, -0.20719098826199578f, -0.5f],

    [1.0f, 1.0f, 1.0f], [2198.050556016380522f, 764.3655248643528689f, 527.107573587542228f], [-0.96269623020744692f, -0.92630200888366945f, -1.4594385811273854f], [-0.76194253026666783f, -0.9675229603596517f, -1.450082094097871593f], [-0.6551140670773547f, -0.27845290869168118f, -1.5843722511996204f],


    [3072.0f, 1024.0f, 384.0f], [3072.0f, 1024.0f, 384.0f], [256.0f, 50.0f, 12.0f],
    [256.0f, 50.0f, 12.0f], [256.0f, 50.0f, 12.0f], [414.0f, 58.0f, 22.0f],
    [0.0f, 0.0f, -0.25f], [0.0f, 0.0f, -0.25f], [0.0f, 0.0f, -0.25f],
    [2198.050556016380522f, 764.3655248643528689f, 527.107573587542228f], [-0.96269623020744692f, -0.92630200888366945f, -1.4594385811273854f], [-0.76194253026666783f, -0.9675229603596517f, -1.450082094097871593f], [-0.6551140670773547f, -0.27845290869168118f, -1.5843722511996204f], [2200.0f, 392.0f, 112.0f], [0.0f, 0.0f, -0.25f], [0.0f, 0.0f, -0.25f], [0.0f, 0.0f, -0.5f],

    [0.9f * 23629.073922049845f, 0.9f * 8611.3238710010046f, 0.9f * 4492.2486445538634f], [-1.025f, -0.3041958212306401f, -1.2f], [-0.78f, 0.3633036457487539f, -1.2f], [-0.65012f, -0.35660379990111464f, -0.8f], [-0.19041574084286472f, -0.3443074455424403f, -0.7f], [-0.20819395464f, -0.33699592683512467f, -0.7f], [-0.421064f, -0.30180866526242109f, -0.4f], [-0.32733845535848671f, -0.27321683125358037f, -0.5f], 
    [0.65f * 23629.073922049845f, 0.65f * 8611.3238710010046f, 0.65f * 4492.2486445538634f], [-1.025f, -0.3041958212306401f, -1.2f], [-0.78f, 0.3633036457487539f, -1.2f], [-0.65012f, -0.35660379990111464f, -0.8f], [-0.19041574084286472f, -0.3443074455424403f, -0.7f], [-0.20819395464f, -0.33699592683512467f, -0.7f], [-0.421064f, -0.30180866526242109f, -0.4f], [-0.32733845535848671f, -0.27321683125358037f, -0.5f], 
    [1.8f * 23629.073922049845f, 1.8f * 8611.3238710010046f, 1.8f * 4492.2486445538634f], [-1.025f, -0.3041958212306401f, -1.2f], [-0.78f, 0.3633036457487539f, -1.2f], [-0.65012f, -0.35660379990111464f, -0.8f], [-0.19041574084286472f, -0.3443074455424403f, -0.7f], [-0.20819395464f, -0.33699592683512467f, -0.7f], [-0.421064f, -0.30180866526242109f, -0.4f], [-0.32733845535848671f, -0.27321683125358037f, -0.5f], 
    [1.3f * 23629.073922049845f, 1.3f * 8611.3238710010046f, 1.3f * 4492.2486445538634f], [-1.025f, -0.3041958212306401f, -1.2f], [-0.78f, 0.3633036457487539f, -1.2f], [-0.65012f, -0.35660379990111464f, -0.8f], [-0.19041574084286472f, -0.3443074455424403f, -0.7f], [-0.20819395464f, -0.33699592683512467f, -0.7f], [-0.421064f, -0.30180866526242109f, -0.4f], [-0.32733845535848671f, -0.27321683125358037f, -0.5f], 
    [3.6f * 23629.073922049845f, 3.6f * 8611.3238710010046f, 3.6f * 4492.2486445538634f], [-1.025f, -0.3041958212306401f, -1.2f], [-0.78f, 0.3633036457487539f, -1.2f], [-0.65012f, -0.35660379990111464f, -0.8f], [-0.19041574084286472f, -0.3443074455424403f, -0.7f], [-0.20819395464f, -0.33699592683512467f, -0.7f], [-0.421064f, -0.30180866526242109f, -0.4f], [-0.32733845535848671f, -0.27321683125358037f, -0.5f], 
    [2.6f * 23629.073922049845f, 2.6f * 8611.3238710010046f, 2.6f * 4492.2486445538634f], [-1.025f, -0.3041958212306401f, -1.2f], [-0.78f, 0.3633036457487539f, -1.2f], [-0.65012f, -0.35660379990111464f, -0.8f], [-0.19041574084286472f, -0.3443074455424403f, -0.7f], [-0.20819395464f, -0.33699592683512467f, -0.7f], [-0.421064f, -0.30180866526242109f, -0.4f], [-0.32733845535848671f, -0.27321683125358037f, -0.5f], 
];


static immutable byte[2][J40__NUM_ORDERS] J40__LOG_ORDER_SIZE = 
[
    [3,3], [3,3], [4,4], [5,5], [3,4], [3,5], [4,5], [6,6], [5,6], [7,7], [6,7], [8,8], [7,8],
];

j40_err j40__read_dq_matrix(
    j40__st *st, int rows, int columns, long raw_sidx,
    j40__tree_node *global_tree, 
    const(j40__code_spec)* global_codespec, 
    j40__dq_matrix *dqmat) 
{
    j40__modular m;
    int c, i, j;

    dqmat.mode = cast(j40__dq_matrix_mode) j40__u(st, 3);
    dqmat.params = null;
    if (dqmat.mode == J40__DQ_ENC_RAW)  // read as a modular image
    {
        float denom, inv_denom;
        int[3] w, h;
        int x, y;

        denom = j40__f16(st);
        // TODO spec bug: ZeroPadToByte isn't required at this point
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__surely_nonzero(denom)) == 0)) { j40__set_error(st, J40__4("dqm0")); goto J40__ON_ERROR; } } while (0);
        inv_denom = 1.0f / denom;

        w[0] = w[1] = w[2] = columns;
        h[0] = h[1] = h[2] = rows;
        do { if (J40_UNLIKELY(j40__init_modular(st, 3, w.ptr, h.ptr, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__modular_header(st, global_tree, global_codespec, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__allocate_modular(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        for (c = 0; c < m.num_channels; ++c) 
        {
            do { if (J40_UNLIKELY(j40__modular_channel(st, &m, c, raw_sidx))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
        do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &m.code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__inverse_transform(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

        dqmat.params = cast(j40_f32x4*) j40__malloc(cast(size_t) (rows * columns), j40_f32x4.sizeof);

        for (c = 0; c < 3; ++c) 
        {
            if (m.channel[c].type == J40__PLANE_I16) 
            {
                for (y = 0; y < rows; ++y) 
                {
                    short *pixels = J40__I16_PIXELS(&m.channel[c], y);
                    for (x = 0; x < columns; ++x) 
                    {
                        dqmat.params[y * columns + x][c] = cast(float) pixels[x] * inv_denom;
                    }
                }
            } 
            else 
            {
                for (y = 0; y < rows; ++y) 
                {
                    int *pixels = J40__I32_PIXELS(&m.channel[c], y);
                    for (x = 0; x < columns; ++x) 
                    {
                        dqmat.params[y * columns + x][c] = cast(float) pixels[x] * inv_denom;
                    }
                }
            }
        }

        j40__free_modular(&m);
        dqmat.n = cast(short) rows;
        dqmat.m = cast(short) columns;
    } 
    else 
    {
        static struct how_t 
        {
            byte requires8x8; // 1 if 8x8 matrix is required
            byte nparams; // the number of fixed parameters
            byte nscaled; // params[0..nscaled-1] should be scaled by 64
            byte ndctparams; // the number of calls to ReadDctParams
        }

        static immutable how_t[7] HOW =
        [
            how_t(0,0,0,0), how_t(1,3,3,0), how_t(1,6,6,0), how_t(1,2,2,1), how_t(1,1,0,1), how_t(1,9,6,2), how_t(1,0,0,1)
        ];
        
        how_t how = HOW[dqmat.mode];
        int paramsize = how.nparams + how.ndctparams * 16, paramidx = how.nparams;
        if (how.requires8x8) 
        {
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((rows == 8 && columns == 8) == 0)) { j40__set_error(st, J40__4("dqm?")); goto J40__ON_ERROR; } } while (0);
        }
        if (paramsize) 
        {
            dqmat.params = cast(j40_f32x4*) j40__malloc(cast(size_t) paramsize, j40_f32x4.sizeof);
            for (c = 0; c < 3; ++c) for (j = 0; j < how.nparams; ++j) 
            {
                dqmat.params[j][c] = j40__f16(st) * (j < how.nscaled ? 64.0f : 1.0f);
            }
            for (i = 0; i < how.ndctparams; ++i)  // ReadDctParams
            { 
                int n = *(i == 0 ? &dqmat.n : &dqmat.m) = cast(short) (j40__u(st, 4) + 1);
                for (c = 0; c < 3; ++c) for (j = 0; j < n; ++j) {
                    dqmat.params[paramidx + j][c] = j40__f16(st) * (j == 0 ? 64.0f : 1.0f);
                }
                paramidx += n;
            }
        }
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
    }
    return 0;

J40__ON_ERROR:
    j40__free(dqmat.params);
    dqmat.params = null;
    j40__free_modular(&m);
    return st.err;
}

// piecewise exponential interpolation where pos is in [0,1], mapping pos = k/(len-1) to bands[k]
float j40__interpolate(float pos, int c, const j40_f32x4 *bands, int len) 
{
    float scaled_pos, frac_idx, a, b;
    int scaled_idx;
    if (len == 1) return bands[0][c];
    scaled_pos = pos * cast(float) (len - 1);
    scaled_idx = cast(int) scaled_pos;
    frac_idx = scaled_pos - cast(float) scaled_idx;
    a = bands[scaled_idx][c];
    b = bands[scaled_idx + 1][c];
    return a * powf(b / a, frac_idx);
}

j40_err j40__interpolation_bands(
    j40__st *st, 
    const(j40_f32x4)* params, 
    int nparams, 
    j40_f32x4 *out_) 
{
    int i, c;
    for (c = 0; c < 3; ++c) 
    {
        // TODO spec bug: loops for x & y are independent of the loop for i (bands)
        // TODO spec bug: `bands(i)` for i >= 0 (not i > 0) should be larger (not no less) than 0
        out_[0][c] = params[0][c];
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((out_[0][c] > 0) == 0)) { j40__set_error(st, J40__4("band")); goto J40__ON_ERROR; } } while (0);
        for (i = 1; i < nparams; ++i) {
            float v = params[i][c];
            out_[i][c] = v > 0 ? out_[i - 1][c] * (1.0f + v) : out_[i - 1][c] / (1.0f - v);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((out_[i][c] > 0) == 0)) { j40__set_error(st, J40__4("band")); goto J40__ON_ERROR; } } while (0);
        }
    }
J40__ON_ERROR:
    return st.err;
}

void j40__dct_quant_weights(int rows, int columns, 
                            const(j40_f32x4)* bands, 
                            int len, 
                            j40_f32x4 *out_) 
{
    float inv_rows_m1 = 1.0f / cast(float) (rows - 1), inv_columns_m1 = 1.0f / cast(float) (columns - 1);
    int x, y, c;
    for (c = 0; c < 3; ++c) {
        for (y = 0; y < rows; ++y) for (x = 0; x < columns; ++x) {
            static const float INV_SQRT2 = 1.0f / 1.414214562373095f; // 1/(sqrt(2) + 1e-6)
            float d = hypotf(cast(float) x * inv_columns_m1, cast(float) y * inv_rows_m1);
            // TODO spec issue: num_bands doesn't exist (probably len)
            out_[y * columns + x][c] = j40__interpolate(d * INV_SQRT2, c, bands, len);
        }
    }
}

// TODO spec issue: VarDCT uses the (row, column) notation, not the (x, y) notation; explicitly note this
// TODO spec improvement: spec can provide computed matrices for default parameters to aid verification
j40_err j40__load_dq_matrix(j40__st *st, int idx, j40__dq_matrix *dqmat) 
{
    enum MAX_BANDS = 15;
    j40__dct_params dct = J40__DCT_PARAMS[idx];
    j40__dq_matrix_mode mode;
    int rows, columns, n, m;
    const(j40_f32x4)* params;
    j40_f32x4*raw = null;
    j40_f32x4[MAX_BANDS] bands;
    j40_f32x4[64] scratch;
    int x, y, i, c;

    mode = dqmat.mode;
    if (mode == J40__DQ_ENC_RAW) 
    {
        return 0; // nothing to do
    } 
    else if (mode == J40__DQ_ENC_LIBRARY) 
    {
        mode = cast(j40__dq_matrix_mode) dct.def_mode;
        n = dct.def_n;
        m = dct.def_m;
        params = J40__LIBRARY_DCT_PARAMS.ptr + dct.def_offset;
    } 
    else 
    {
        n = dqmat.n;
        m = dqmat.m;
        params = dqmat.params;
    }

    rows = 1 << dct.log_rows;
    columns = 1 << dct.log_columns;

    raw = cast(j40_f32x4*) j40__malloc(cast(size_t) (rows * columns), j40_f32x4.sizeof);

    switch (mode) 
    {
    case J40__DQ_ENC_DCT:
        do { if (J40_UNLIKELY(j40__interpolation_bands(st, params, n, bands.ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__dct_quant_weights(rows, columns, bands.ptr, n, raw);
        break;

    case J40__DQ_ENC_DCT4:
        assert(rows == 8 && columns == 8);
        assert(n <= MAX_BANDS);
        do { if (J40_UNLIKELY(j40__interpolation_bands(st, params + 2, n, bands.ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__dct_quant_weights(4, 4, bands.ptr, n, scratch.ptr);
        for (c = 0; c < 3; ++c) {
            for (y = 0; y < 8; ++y) for (x = 0; x < 8; ++x) {
                raw[y * 8 + x][c] = scratch[(y / 2) * 4 + (x / 2)][c];
            }
            raw[1][c] /= params[0][c];
            raw[8][c] /= params[0][c];
            raw[9][c] /= params[1][c];
        }
        break;

    case J40__DQ_ENC_DCT2:
        assert(rows == 8 && columns == 8);
        for (c = 0; c < 3; ++c) 
        {
            static immutable byte[64] MAP = 
            [
                // TODO spec issue: coefficient (0,0) is unspecified; means it shouldn't be touched
                0,0,2,2,4,4,4,4,
                0,1,2,2,4,4,4,4,
                2,2,3,3,4,4,4,4,
                2,2,3,3,4,4,4,4,
                4,4,4,4,5,5,5,5,
                4,4,4,4,5,5,5,5,
                4,4,4,4,5,5,5,5,
                4,4,4,4,5,5,5,5,
            ];
            for (i = 0; i < 64; ++i) 
                raw[i][c] = params[MAP[i]][c];
            raw[0][c] = -1.0f;
        }
        break;

    case J40__DQ_ENC_HORNUSS:
        assert(rows == 8 && columns == 8);
        for (c = 0; c < 3; ++c) {
            for (i = 0; i < 64; ++i) raw[i][c] = params[0][c];
            raw[0][c] = 1.0f;
            raw[1][c] = raw[8][c] = params[1][c];
            raw[9][c] = params[2][c];
        }
        break;

    case J40__DQ_ENC_DCT4X8:
        assert(rows == 8 && columns == 8);
        assert(n <= MAX_BANDS);
        do { if (J40_UNLIKELY(j40__interpolation_bands(st, params + 1, n, bands.ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        // TODO spec bug: 4 rows by 8 columns, not 8 rows by 4 columns (compare with AFV weights4x8)
        // the position (x, y Idiv 2) is also confusing, since it's using the (x, y) notation
        j40__dct_quant_weights(4, 8, bands.ptr, n, scratch.ptr);
        for (c = 0; c < 3; ++c) {
            for (y = 0; y < 8; ++y) for (x = 0; x < 8; ++x) {
                raw[y * 8 + x][c] = scratch[(y / 2) * 8 + x][c];
            }
            raw[1][c] /= params[0][c];
        }
        break;

    case J40__DQ_ENC_AFV:
        assert(rows == 8 && columns == 8);
        assert(n <= MAX_BANDS && m <= MAX_BANDS);
        do { if (J40_UNLIKELY(j40__interpolation_bands(st, params + 9, n, bands.ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__dct_quant_weights(4, 8, bands.ptr, n, scratch.ptr);
        do { if (J40_UNLIKELY(j40__interpolation_bands(st, params + 9 + n, m, bands.ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__dct_quant_weights(4, 4, bands.ptr, m, scratch.ptr + 32);
        do { if (J40_UNLIKELY(j40__interpolation_bands(st, params + 5, 4, bands.ptr))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        for (c = 0; c < 3; ++c) 
        {
            // TODO spec bug: this value can never be 1 because it will result in an out-of-bound
            // access in j40__interpolate; libjxl avoids this by adding 1e-6 to the denominator
            static immutable float[12] FREQS = 
            [ // precomputed values of (freqs[i] - lo) / (hi - lo + 1e-6)
                0.000000000f, 0.373436417f, 0.320380100f, 0.379332596f, 0.066671353f, 0.259756761f,
                0.530035651f, 0.789731061f, 0.149436598f, 0.559318823f, 0.669198646f, 0.999999917f,
            ];
            scratch[0][c] = params[0][c]; // replaces the top-left corner of weights4x8
            scratch[32][c] = params[1][c]; // replaces the top-left corner of weights4x4
            for (i = 0; i < 12; ++i) scratch[i + 48][c] = j40__interpolate(FREQS[i], c, bands.ptr, 4);
            scratch[60][c] = 1.0f;
            for (i = 0; i < 3; ++i) scratch[i + 61][c] = params[i + 2][c];
        }
        for (c = 0; c < 3; ++c) {
            // TODO spec bug: `weight(...)` uses multiple conflicting notations
            static const byte[64] MAP2 = 
            [
                // 1..31 from weights4x8, 33..47 from weights4x4, 48..59 interpolated,
                // 0/32/61..63 directly from parameters, 60 fixed to 1.0
                60, 32, 62, 33, 48, 34, 49, 35,
                 0,  1,  2,  3,  4,  5,  6,  7,
                61, 36, 63, 37, 50, 38, 51, 39,
                 8,  9, 10, 11, 12, 13, 14, 15,
                52, 40, 53, 41, 54, 42, 55, 43,
                16, 17, 18, 19, 20, 21, 22, 23,
                56, 44, 57, 45, 58, 46, 59, 47,
                24, 25, 26, 27, 28, 29, 30, 31,
            ];
            for (i = 0; i < 64; ++i) raw[i][c] = scratch[MAP2[i]][c];
        }
        break;

    default: J40__UNREACHABLE();
    }

    j40__free(dqmat.params);
    dqmat.mode = J40__DQ_ENC_RAW;
    dqmat.n = cast(short) rows;
    dqmat.m = cast(short) columns;
    dqmat.params = raw;
    return 0;

J40__ON_ERROR:
    j40__free(raw);
    return st.err;
}

void j40__free_dq_matrix(j40__dq_matrix *dqmat) {
    if (dqmat.mode != J40__DQ_ENC_LIBRARY) j40__free(dqmat.params);
    dqmat.mode = J40__DQ_ENC_LIBRARY;
    dqmat.params = null;
}

j40_err j40__natural_order(j40__st *st, int log_rows, int log_columns, int **out_) 
{
    int size = 1 << (log_rows + log_columns), log_slope = log_columns - log_rows;
    int rows8 = 1 << (log_rows - 3), columns8 = 1 << (log_columns - 3);
    int *order = null;
    int y, x, key1, o;

    assert(8 >= log_columns && log_columns >= log_rows && log_rows >= 3);

    order = cast(int*) j40__malloc(cast(size_t) size, int.sizeof);

    o = 0;
    for (y = 0; y < rows8; ++y) for (x = 0; x < columns8; ++x) {
        order[o++] = y << log_columns | x;
    }

    //            d e..
    // +---------/-/-  each diagonal is identified by an integer
    // |       |/ / /    key1 = scaled_x + scaled_y = x + y * 2^log_slope,
    // |_a_b_c_| / /   and covers at least one cell when:
    // |/ / / / / / /    2^(log_columns - 3) <= key1 < 2^(log_columns + 1) - 2^log_slope.
    for (key1 = 1 << (log_columns - 3); o < size; ++key1) {
        // place initial endpoints to leftmost and topmost edges, then fix out-of-bounds later
        int x0 = key1 & ((1 << log_slope) - 1), y0 = key1 >> log_slope, x1 = key1, y1 = 0;
        if (x1 >= (1 << log_columns)) {
            int excess = j40__ceil_div32(x1 - ((1 << log_columns) - 1), 1 << log_slope);
            x1 -= excess << log_slope;
            y1 += excess;
            assert(x1 >= 0 && y1 < (1 << log_rows));
        }
        if (y0 >= (1 << log_rows)) {
            int excess = y0 - ((1 << log_rows) - 1);
            x0 += excess << log_slope;
            y0 -= excess;
            assert(x0 < (1 << log_columns) && y0 >= 0);
        }
        assert(o + (y0 - y1 + 1) <= size);
        if (key1 & 1) {
            for (x = x1, y = y1; x >= x0; x -= 1 << log_slope, ++y) {
                // skip the already covered top-left LLF region
                if (y >= rows8 || x >= columns8) order[o++] = y << log_columns | x;
            }
        } else {
            for (x = x0, y = y0; x <= x1; x += 1 << log_slope, --y) {
                if (y >= rows8 || x >= columns8) order[o++] = y << log_columns | x;
            }
        }
    }
    assert(o == size);

    *out_ = order;
    return 0;

J40__ON_ERROR:
    j40__free(order);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// frame context

enum 
{
    J40__MAX_PASSES = 11,
}

enum 
{
    J40__BLEND_REPLACE = 0, // new
    J40__BLEND_ADD = 1,     // old + new
    J40__BLEND_BLEND = 2,   // new + old * (1 - new alpha) or equivalent, optionally clamped
    J40__BLEND_MUL_ADD = 3, // old + new * alpha or equivalent, optionally clamped
    J40__BLEND_MUL = 4,     // old * new, optionally clamped
}

struct j40__blend_info
{
    byte mode, alpha_chan, clamp, src_ref_frame;
}

alias j40__frame_type = int;
enum : j40__frame_type 
{
    J40__FRAME_REGULAR = 0, 
    J40__FRAME_LF = 1, 
    J40__FRAME_REFONLY = 2, 
    J40__FRAME_REGULAR_SKIPPROG = 3
}

struct j40__frame_st 
{
    int is_last;
    j40__frame_type type;
    int is_modular; // VarDCT if false
    int has_noise, has_patches, has_splines, use_lf_frame, skip_adapt_lf_smooth;
    int do_ycbcr;
    int jpeg_upsampling; // [0] | [1] << 2 | [2] << 4
    int log_upsampling;
    int* ec_log_upsampling;
    int group_size_shift;
    int x_qm_scale, b_qm_scale;
    int num_passes;
    byte[J40__MAX_PASSES] shift;
    byte[J40__MAX_PASSES + 1] log_ds; // pass i shift range is [log_ds[i+1], log_ds[i])
    int lf_level;
    int x0, y0, width, height;
    int grows, gcolumns, ggrows, ggcolumns;
    // there can be at most (2^23 + 146)^2 groups and (2^20 + 29)^2 LF groups in a single frame
    long num_groups, num_lf_groups;
    long duration, timecode;
    j40__blend_info blend_info;
    j40__blend_info* ec_blend_info;
    int save_as_ref;
    int save_before_ct;
    int name_len;
    char *name;

    static struct gab_t
    {
        int enabled;
        float[2 /*0=weight1 (cardinal/center), 1=weight2 (diagonal/center)*/][3 /*xyb*/] weights;
    }
    gab_t gab;

    static struct epf_t
    {
        int iters;
        float[8] sharp_lut;
        float[3] channel_scale;
        float quant_mul, pass0_sigma_scale, pass2_sigma_scale, 
              border_sad_mul, sigma_for_modular;
    }
    epf_t epf;

    // TODO spec bug: m_*_lf_unscaled are wildly incorrect, both in default values and scaling
    float[3 /*xyb*/] m_lf_scaled;
    j40__tree_node *global_tree;
    j40__code_spec global_codespec;

    // modular only, available after LfGlobal (local groups are always pasted into gmodular)
    j40__modular gmodular;
    int num_gm_channels; // <= gmodular.num_channels

    // vardct only, available after LfGlobal
    int global_scale, quant_lf;
    int[15][3 /*xyb*/] lf_thr;
    int[15] qf_thr;
    int[3 /*xyb*/] nb_lf_thr;
    int nb_qf_thr;
    ubyte *block_ctx_map;
    int block_ctx_size, nb_block_ctx;
    float inv_colour_factor;
    int x_factor_lf, b_factor_lf;
    float base_corr_x = 0, 
          base_corr_b = 0;

    // vardct only, available after HfGlobal/HfPass
    int dct_select_used, dct_select_loaded; // i-th bit for DctSelect i
    int order_used, order_loaded; // i-th bit for order i
    j40__dq_matrix[J40__NUM_DCT_PARAMS] dq_matrix;
    int num_hf_presets;
    // Lehmer code + sentinel (-1) before actual coefficient decoding,
    // either properly computed or discarded due to non-use later (can be null in that case)
    int*[3 /*xyb*/][J40__NUM_ORDERS][J40__MAX_PASSES] orders;

    j40__code_spec[J40__MAX_PASSES] coeff_codespec;
}


void j40__free_frame_state(j40__frame_st *f) 
{
    int i, j, k;
    j40__free(f.ec_log_upsampling);
    j40__free(f.ec_blend_info);
    j40__free(f.name);
    j40__free(f.global_tree);
    j40__free_code_spec(&f.global_codespec);
    j40__free_modular(&f.gmodular);
    j40__free(f.block_ctx_map);
    for (i = 0; i < J40__NUM_DCT_PARAMS; ++i) 
        j40__free_dq_matrix(&f.dq_matrix[i]);
    for (i = 0; i < J40__MAX_PASSES; ++i) 
    {
        for (j = 0; j < J40__NUM_ORDERS; ++j) 
        {
            for (k = 0; k < 3; ++k) 
            {
                j40__free(f.orders[i][j][k]);
                f.orders[i][j][k] = null;
            }
        }
        j40__free_code_spec(&f.coeff_codespec[i]);
    }
    f.ec_log_upsampling = null;
    f.ec_blend_info = null;
    f.name = null;
    f.global_tree = null;
    f.block_ctx_map = null;
}

////////////////////////////////////////////////////////////////////////////////
// frame header

j40_err j40__frame_header(j40__st *st) 
{
    j40__image_st *im = st.image;
    j40__frame_st *f = st.frame;
    int i, j;

    f.is_last = 1;
    f.type = J40__FRAME_REGULAR;
    f.is_modular = 0;
    f.has_noise = f.has_patches = f.has_splines = f.use_lf_frame = f.skip_adapt_lf_smooth = 0;
    f.do_ycbcr = 0;
    f.jpeg_upsampling = 0;
    f.log_upsampling = 0;
    f.ec_log_upsampling = null;
    f.group_size_shift = 8;
    f.x_qm_scale = 3;
    f.b_qm_scale = 2;
    f.num_passes = 1;
    f.shift[0] = 0; // last pass if default
    f.log_ds[0] = 3; f.log_ds[1] = 0; // last pass if default
    f.lf_level = 0;
    f.x0 = f.y0 = 0;
    f.width = im.width;
    f.height = im.height;
    f.duration = f.timecode = 0;
    f.blend_info.mode = J40__BLEND_REPLACE;
    f.blend_info.alpha_chan = 0; // XXX set to the actual alpha channel
    f.blend_info.clamp = 0;
    f.blend_info.src_ref_frame = 0;
    f.ec_blend_info = null;
    f.save_as_ref = 0;
    f.save_before_ct = 1;
    f.name_len = 0;
    f.name = null;
    f.gab.enabled = 1;
    f.gab.weights[0][0] = f.gab.weights[1][0] = f.gab.weights[2][0] = 0.115169525f;
    f.gab.weights[0][1] = f.gab.weights[1][1] = f.gab.weights[2][1] = 0.061248592f;
    f.epf.iters = 2;
    for (i = 0; i < 8; ++i) 
        f.epf.sharp_lut[i] = cast(float) i / 7.0f;
    f.epf.channel_scale[0] = 40.0f;
    f.epf.channel_scale[1] = 5.0f;
    f.epf.channel_scale[2] = 3.5f;
    f.epf.quant_mul = 0.46f;
    f.epf.pass0_sigma_scale = 0.9f;
    f.epf.pass2_sigma_scale = 6.5f;
    f.epf.border_sad_mul = 2.0f / 3.0f;
    f.epf.sigma_for_modular = 1.0f;
    // TODO spec bug: default values for m_*_lf_unscaled should be reciprocals of the listed values
    f.m_lf_scaled[0] = 1.0f / 4096.0f;
    f.m_lf_scaled[1] = 1.0f / 512.0f;
    f.m_lf_scaled[2] = 1.0f / 256.0f;
    f.global_tree = null;
    memset(&f.global_codespec, 0, j40__code_spec.sizeof);
    memset(&f.gmodular, 0, j40__modular.sizeof);
    f.block_ctx_map = null;
    f.inv_colour_factor = 1 / 84.0f;
    f.x_factor_lf = 0;
    f.b_factor_lf = 0;
    f.base_corr_x = 0.0f;
    f.base_corr_b = 1.0f;
    f.dct_select_used = f.dct_select_loaded = 0;
    f.order_used = f.order_loaded = 0;
    memset(f.dq_matrix.ptr, 0, f.dq_matrix.sizeof);
    memset(f.orders.ptr, 0, f.orders.sizeof);
    memset(f.coeff_codespec.ptr, 0, f.coeff_codespec.sizeof);

    do { if (J40_UNLIKELY(j40__zero_pad_to_byte(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    if (!j40__u(st, 1)) { // !all_default
        int full_frame = 1;
        ulong flags;
        f.type = cast(j40__frame_type) j40__u(st, 2);
        f.is_modular = j40__u(st, 1);
        flags = j40__u64(st);
        f.has_noise = cast(int) (flags & 1);
        f.has_patches = cast(int) (flags >> 1 & 1);
        f.has_splines = cast(int) (flags >> 4 & 1);
        f.use_lf_frame = cast(int) (flags >> 5 & 1);
        f.skip_adapt_lf_smooth = cast(int) (flags >> 7 & 1);
        if (!im.xyb_encoded) f.do_ycbcr = j40__u(st, 1);
        if (!f.use_lf_frame) {
            if (f.do_ycbcr) f.jpeg_upsampling = j40__u(st, 6); // yes, we are lazy
            f.log_upsampling = j40__u(st, 2);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((f.log_upsampling == 0) == 0)) { j40__set_error(st, J40__4("TODO: upsampling is not yet implemented")); goto J40__ON_ERROR; } } while (0);
            f.ec_log_upsampling = cast(int*) j40__malloc(cast(size_t) im.num_extra_channels, int.sizeof);

            for (i = 0; i < im.num_extra_channels; ++i) {
                f.ec_log_upsampling[i] = j40__u(st, 2);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((f.ec_log_upsampling[i] == 0) == 0)) { j40__set_error(st, J40__4("TODO: upsampling is not yet implemented")); goto J40__ON_ERROR; } } while (0);
            }
        }
        if (f.is_modular) {
            f.group_size_shift = 7 + j40__u(st, 2);
        } else if (im.xyb_encoded) {
            f.x_qm_scale = j40__u(st, 3);
            f.b_qm_scale = j40__u(st, 3);
        }
        if (f.type != J40__FRAME_REFONLY) 
        {
            f.num_passes = j40__u32(st, 1, 0, 2, 0, 3, 0, 4, 3);
            if (f.num_passes > 1) {
                // SPEC this part is especially flaky and the spec and libjxl don't agree to each other.
                // we do the most sensible thing that is still compatible to libjxl:
                // - downsample should be decreasing (or stay same)
                // - last_pass should be strictly increasing and last_pass[0] (if any) should be 0
                // see also https://github.com/libjxl/libjxl/issues/1401
                byte[4] log_ds;
                int ppass = 0, num_ds = j40__u32(st, 0, 0, 1, 0, 2, 0, 3, 1);
                do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((num_ds < f.num_passes) == 0)) { j40__set_error(st, J40__4("pass")); goto J40__ON_ERROR; } } while (0);
                for (i = 0; i < f.num_passes - 1; ++i) f.shift[i] = cast(byte) j40__u(st, 2);
                f.shift[f.num_passes - 1] = 0;
                for (i = 0; i < num_ds; ++i) {
                    log_ds[i] = cast(byte) j40__u(st, 2);
                    if (i > 0)
                    {
                        if (J40_UNLIKELY(st.err)) 
                            goto J40__ON_ERROR;
                        if (J40_UNLIKELY((log_ds[i - 1] >= log_ds[i]) == 0)) 
                        { 
                            j40__set_error(st, J40__4("pass")); 
                            goto J40__ON_ERROR; 
                        }
                    }
                }
                for (i = 0; i < num_ds; ++i) {
                    int pass = j40__u32(st, 0, 0, 1, 0, 2, 0, 0, 3);
                    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((i > 0 ? ppass < pass && pass < f.num_passes : pass == 0) == 0)) { j40__set_error(st, J40__4("pass")); goto J40__ON_ERROR; } } while (0);
                    while (ppass < pass) f.log_ds[++ppass] = i > 0 ? log_ds[i - 1] : 3;
                }
                while (ppass < f.num_passes) f.log_ds[++ppass] = i > 0 ? log_ds[num_ds - 1] : 3;
            }
        }
        if (f.type == J40__FRAME_LF) {
            f.lf_level = j40__u(st, 2) + 1;
        } else if (j40__u(st, 1)) { // have_crop
            if (f.type != J40__FRAME_REFONLY) { // SPEC missing UnpackSigned
                f.x0 = j40__unpack_signed(j40__u32(st, 0, 8, 256, 11, 2304, 14, 18688, 30));
                f.y0 = j40__unpack_signed(j40__u32(st, 0, 8, 256, 11, 2304, 14, 18688, 30));
            }
            f.width = j40__u32(st, 0, 8, 256, 11, 2304, 14, 18688, 30);
            f.height = j40__u32(st, 0, 8, 256, 11, 2304, 14, 18688, 30);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((f.width <= st.limits.width && f.height <= st.limits.height) == 0)) { j40__set_error(st, J40__4("slim")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((cast(long) f.width * f.height <= st.limits.pixels) == 0)) { j40__set_error(st, J40__4("slim")); goto J40__ON_ERROR; } } while (0);
            full_frame = f.x0 <= 0 && f.y0 <= 0 &&
                f.width + f.x0 >= im.width && f.height + f.y0 >= im.height;
        }
        if (f.type == J40__FRAME_REGULAR || f.type == J40__FRAME_REGULAR_SKIPPROG) 
        {
            f.ec_blend_info = cast(j40__blend_info*) j40__malloc(cast(size_t) im.num_extra_channels, j40__blend_info.sizeof);

            for (i = -1; i < im.num_extra_channels; ++i) {
                j40__blend_info *blend = i < 0 ? &f.blend_info : &f.ec_blend_info[i];
                blend.mode = cast(byte) j40__u32(st, 0, 0, 1, 0, 2, 0, 3, 2);
                if (im.num_extra_channels > 0) {
                    if (blend.mode == J40__BLEND_BLEND || blend.mode == J40__BLEND_MUL_ADD) {
                        blend.alpha_chan = cast(byte) j40__u32(st, 0, 0, 1, 0, 2, 0, 3, 3);
                        blend.clamp = cast(byte) j40__u(st, 1);
                    } else if (blend.mode == J40__BLEND_MUL) {
                        blend.clamp = cast(byte) j40__u(st, 1);
                    }
                }
                if (!full_frame || blend.mode != J40__BLEND_REPLACE) {
                    blend.src_ref_frame = cast(byte) j40__u(st, 2);
                }
            }
            if (im.anim_tps_denom) { // have_animation stored implicitly
                f.duration = j40__64u32(st, 0, 0, 1, 0, 0, 8, 0, 32);
                if (im.anim_have_timecodes) {
                    f.timecode = j40__64u(st, 32);
                }
            }
            f.is_last = j40__u(st, 1);
        } else {
            f.is_last = 0;
        }
        if (f.type != J40__FRAME_LF && !f.is_last) f.save_as_ref = j40__u(st, 2);
        // SPEC this condition is essentially swapped with the default value in the spec
        if (f.type == J40__FRAME_REFONLY || (
            full_frame &&
            (f.type == J40__FRAME_REGULAR || f.type == J40__FRAME_REGULAR_SKIPPROG) &&
            f.blend_info.mode == J40__BLEND_REPLACE &&
            (f.duration == 0 || f.save_as_ref != 0) &&
            !f.is_last
        )) {
            f.save_before_ct = j40__u(st, 1);
        } else {
            f.save_before_ct = (f.type == J40__FRAME_LF);
        }
        do { if (J40_UNLIKELY(j40__name(st, &f.name_len, &f.name))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        { // RestorationFilter
            int restoration_all_default = j40__u(st, 1);
            f.gab.enabled = restoration_all_default ? 1 : j40__u(st, 1);
            if (f.gab.enabled) {
                if (j40__u(st, 1)) { // gab_custom
                    for (i = 0; i < 3; ++i) {
                        for (j = 0; j < 2; ++j) f.gab.weights[i][j] = j40__f16(st);
                    }
                }
            }
            f.epf.iters = restoration_all_default ? 2 : j40__u(st, 2);
            if (f.epf.iters) {
                if (!f.is_modular && j40__u(st, 1)) { // epf_sharp_custom
                    for (i = 0; i < 8; ++i) f.epf.sharp_lut[i] = j40__f16(st);
                }
                if (j40__u(st, 1)) { // epf_weight_custom
                    for (i = 0; i < 3; ++i) f.epf.channel_scale[i] = j40__f16(st);
                    do { if (J40_UNLIKELY(j40__skip(st, 32))) { assert(st.err); goto J40__ON_ERROR; } } while (0); 
                }
                if (j40__u(st, 1)) { // epf_sigma_custom
                    if (!f.is_modular) f.epf.quant_mul = j40__f16(st);
                    f.epf.pass0_sigma_scale = j40__f16(st);
                    f.epf.pass2_sigma_scale = j40__f16(st);
                    f.epf.border_sad_mul = j40__f16(st);
                }
                if (f.epf.iters && f.is_modular) f.epf.sigma_for_modular = j40__f16(st);
            }
            if (!restoration_all_default) do { if (J40_UNLIKELY(j40__extensions(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
        do { if (J40_UNLIKELY(j40__extensions(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);

    if (im.xyb_encoded && im.want_icc) f.save_before_ct = 1; // ignores the decoded bit
    f.grows = j40__ceil_div32(f.height, 1 << f.group_size_shift);
    f.gcolumns = j40__ceil_div32(f.width, 1 << f.group_size_shift);
    f.num_groups = cast(long) f.grows * f.gcolumns;
    f.ggrows = j40__ceil_div32(f.height, 8 << f.group_size_shift);
    f.ggcolumns = j40__ceil_div32(f.width, 8 << f.group_size_shift);
    f.num_lf_groups = cast(long) f.ggrows * f.ggcolumns;
    return 0;

J40__ON_ERROR:
    j40__free(f.ec_log_upsampling);
    j40__free(f.ec_blend_info);
    j40__free(f.name);
    f.ec_log_upsampling = null;
    f.ec_blend_info = null;
    f.name = null;
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// frame header

struct j40__section
{
    long idx; // either LF group index (pass < 0) or group index (pass >= 0)
    long codeoff;
    int size;
    int pass; // pass number, or negative if this is an LF group section
}

struct j40__toc
{
    // if nonzero, there is only single section of this size and other fields are ignored
    int single_size;

    // LfGlobal and HfGlobal are common dependencies of other sections, and handled separately
    long lf_global_codeoff, hf_global_codeoff;
    int lf_global_size, hf_global_size;

    // other sections are ordered by codeoff, unless the earlier section needs the later section
    // for decoding, in which case the order gets swapped
    long nsections, nsections_read;
    j40__section *sections;
    long end_codeoff;
}

// also used in j40__hf_global; out is terminated by a sentinel (-1) or null if empty
// TODO permutation may have to handle more than 2^31 entries
j40_err j40__permutation(
    j40__st *st, j40__code_st *code, int size, int skip, int **out_
) {
    int *arr = null;
    int i, prev, end;

    assert(code.spec.num_dist == 8 + !!code.spec.lz77_enabled);

    // SPEC this is the number of integers to read, not the last offset to read (can differ when skip > 0)
    end = j40__code(st, j40__min32(7, j40__ceil_lg32(cast(uint) size + 1)), 0, code);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((end <= size - skip) == 0)) { j40__set_error(st, J40__4("perm")); goto J40__ON_ERROR; } } while (0);   // SPEC missing
    if (end == 0) {
        *out_ = null;
        return 0;
    }

    arr = cast(int*) j40__malloc(cast(size_t) (end + 1), int.sizeof);

    prev = 0;
    for (i = 0; i < end; ++i) {
        prev = arr[i] = j40__code(st, j40__min32(7, j40__ceil_lg32(cast(uint) prev + 1)), 0, code);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((prev < size - (skip + i)) == 0)) { j40__set_error(st, J40__4("perm")); goto J40__ON_ERROR; } } while (0);   // SPEC missing
    }
    arr[end] = -1; // sentinel
    *out_ = arr;
    return 0;

J40__ON_ERROR:
    free(arr);
    return st.err;
}

// target is pre-shifted by skip
void j40__apply_permutation(
    void *targetbuf, void *temp, size_t elemsize, const(int)* lehmer
) {
    char *target = cast(char*) targetbuf;
    if (!lehmer) return;
    while (*lehmer >= 0) {
        size_t x = cast(size_t) *lehmer++;
        memcpy(temp, target + elemsize * x, elemsize);
        memmove(target + elemsize, target, elemsize * x);
        memcpy(target, temp, elemsize);
        target += elemsize;
    }
}

extern(C)
int j40__compare_section(const void *a, const void *b) {
    const j40__section* aa = cast(const j40__section*) a, 
                        bb = cast(const j40__section*) b;
    return aa.codeoff < bb.codeoff ? -1 : aa.codeoff > bb.codeoff ? 1 : 0;
}

j40_err j40__read_toc(j40__st *st, j40__toc *toc) {
    j40__frame_st *f = st.frame;

    long nsections = f.num_passes == 1 && f.num_groups == 1 ? 1 :
        1 /*lf_global*/ + f.num_lf_groups /*lf_group*/ +
        1 /*hf_global + hf_pass*/ + f.num_passes * f.num_groups /*group_pass*/;
    long nsections2;
    j40__section* sections = null, 
                  sections2 = null;
    j40__section temp;

    // interleaved linked lists for each LF group; for each LF group `gg` there are three cases:
    // - no relocated section if `relocs[gg].next == 0` (initial state).
    // - a single relocated section `relocs[gg].section` if `relocs[gg].next < 0`.
    // - 2+ relocated sections `relocs[i].section`, where `k` starts at `gg` and
    //   continues through `next` until it's negative.
    static struct reloc 
    { 
        long next; 
        j40__section section; 
    }
    reloc* relocs = null;
    long nrelocs, relocs_cap;

    int *lehmer = null;
    j40__code_spec codespec;
    j40__code_st code;
    int i; 
    long nremoved;
    int pass;

    // TODO remove int restrictions
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((cast(ulong) nsections <= SIZE_MAX && nsections <= INT32_MAX) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);

    if (j40__u(st, 1)) { // permuted
        do { if (J40_UNLIKELY(j40__read_code_spec(st, 8, &codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__init_code(&code, &codespec);
        do { if (J40_UNLIKELY(j40__permutation(st, &code, cast(int) nsections, 0, &lehmer))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__free_code_spec(&codespec);
    }
    do { if (J40_UNLIKELY(j40__zero_pad_to_byte(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    // single section case: no allocation required
    if (nsections == 1) {
        toc.single_size = j40__u32(st, 0, 10, 1024, 14, 17408, 22, 4211712, 30);
        do { if (J40_UNLIKELY(j40__zero_pad_to_byte(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        toc.lf_global_codeoff = toc.hf_global_codeoff = 0;
        toc.lf_global_size = toc.hf_global_size = 0;
        toc.nsections = toc.nsections_read = 0;
        toc.sections = null;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__add64(j40__codestream_offset(st), toc.single_size, &toc.end_codeoff)) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);
        j40__free(lehmer);
        return 0;
    }

    sections = cast(j40__section*) j40__malloc(cast(size_t) nsections, j40__section.sizeof);

    for (i = 0; i < nsections; ++i) {
        sections[i].size = j40__u32(st, 0, 10, 1024, 14, 17408, 22, 4211712, 30);
    }
    do { if (J40_UNLIKELY(j40__zero_pad_to_byte(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    sections[0].codeoff = j40__codestream_offset(st); // all TOC offsets are relative to this point
    for (i = 1; i < nsections; ++i) {
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__add64(sections[i-1].codeoff, sections[i-1].size, &sections[i].codeoff)) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);
    }
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__add64(sections[i-1].codeoff, sections[i-1].size, &toc.end_codeoff)) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);

    if (lehmer) 
    {
        j40__apply_permutation(sections, &temp, j40__section.sizeof, lehmer);
        j40__free(lehmer);
        lehmer = null;
    }

    toc.lf_global_codeoff = sections[0].codeoff;
    toc.lf_global_size = sections[0].size;
    sections[0].codeoff = -1;
    for (i = 0; i < f.num_lf_groups; ++i) {
        sections[i + 1].pass = -1;
        sections[i + 1].idx = i;
    }
    toc.hf_global_codeoff = sections[cast(int)f.num_lf_groups + 1].codeoff;
    toc.hf_global_size = sections[cast(int)f.num_lf_groups + 1].size;
    sections[cast(int)f.num_lf_groups + 1].codeoff = -1;
    for (pass = 0; pass < f.num_passes; ++pass) {
        long sectionid = 1 + f.num_lf_groups + 1 + pass * f.num_groups;
        for (i = 0; i < f.num_groups; ++i) {
            sections[cast(int)sectionid + i].pass = pass;
            sections[cast(int)sectionid + i].idx = i;
        }
    }

    // any group section depending on the later LF group section is temporarily moved to relocs
    {
        int ggrow, ggcolumn;

        relocs = cast(reloc*) j40__calloc(cast(size_t) f.num_lf_groups, reloc.sizeof);
        nrelocs = relocs_cap = f.num_lf_groups;

        for (ggrow = 0; ggrow < f.ggrows; ++ggrow) 
        {
            for (ggcolumn = 0; ggcolumn < f.ggcolumns; ++ggcolumn) 
            {
                long ggidx = cast(long) ggrow * f.ggcolumns + ggcolumn, ggsection = 1 + ggidx;
                long ggcodeoff = sections[cast(int)ggsection].codeoff;
                long gsection_base =
                    1 + f.num_lf_groups + 1 + cast(long) (ggrow * 8) * f.gcolumns + (ggcolumn * 8);
                int grows_in_gg = j40__min32((ggrow + 1) * 8, f.grows) - ggrow * 8;
                int gcolumns_in_gg = j40__min32((ggcolumn + 1) * 8, f.gcolumns) - ggcolumn * 8;
                int grow_in_gg, gcolumn_in_gg;

                for (pass = 0; pass < f.num_passes; ++pass) {
                    for (grow_in_gg = 0; grow_in_gg < grows_in_gg; ++grow_in_gg) {
                        for (gcolumn_in_gg = 0; gcolumn_in_gg < gcolumns_in_gg; ++gcolumn_in_gg) {
                            long gsection = gsection_base + pass * f.num_groups + 
                                (grow_in_gg * f.gcolumns + gcolumn_in_gg);
                            if (sections[cast(int)gsection].codeoff > ggcodeoff) continue;
                            if (relocs[cast(int)ggidx].next) 
                            {
                                relocs = cast(reloc*) j40__realloc64(st, relocs, reloc.sizeof, nrelocs + 1, &relocs_cap);

                                relocs[cast(int)nrelocs] = relocs[cast(int)ggidx];
                                relocs[cast(int)ggidx].next = nrelocs++;
                            } else {
                                relocs[cast(int)ggidx].next = -1;
                            }
                            relocs[cast(int)ggidx].section = sections[cast(int)gsection];
                            sections[cast(int)gsection].codeoff = -1;
                        }
                    }
                }
            }
        }
    }

    // remove any section with a codeoff -1 and sort the remainder
    for (i = nremoved = 0; i < nsections; ++i) {
        if (sections[i].codeoff < 0) {
            ++nremoved;
        } else {
            sections[cast(int)(i - nremoved)] = sections[i];
        }
    }
    qsort(sections, cast(size_t) (nsections - nremoved), j40__section.sizeof, &j40__compare_section);

    // copy sections to sections2, but insert any relocated sections after corresponding LF group section
    sections2 = cast(j40__section*) j40__malloc(cast(size_t) nsections, j40__section.sizeof);
    
    nsections2 = 0;
    for (i = 0; i < nsections - nremoved; ++i) {
        long j, first_reloc_off;
        sections2[cast(int)(nsections2++)] = sections[i];
        if (sections[i].pass >= 0) continue;
        j = sections[i].idx;
        if (!relocs[cast(int)j].next) continue;
        first_reloc_off = nsections2;
        while (j >= 0) {
            sections2[cast(int)(nsections2++)] = relocs[cast(int)j].section;
            j = relocs[cast(int)j].next;
        }
        qsort(sections2 + first_reloc_off, cast(size_t) (nsections2 - first_reloc_off),
            j40__section.sizeof, &j40__compare_section);
    }

    toc.sections = sections2;
    toc.nsections = nsections2;
    toc.nsections_read = 0;
    assert(nsections2 == nsections - 2); // excludes LfGlobal and HfGlobal

    j40__free(sections);
    j40__free(relocs);
    j40__free(lehmer);
    j40__free_code(&code);
    j40__free_code_spec(&codespec);
    return 0;

J40__ON_ERROR:
    j40__free(sections);
    j40__free(sections2);
    j40__free(relocs);
    j40__free(lehmer);
    j40__free_code(&code);
    j40__free_code_spec(&codespec);
    return st.err;
}

void j40__free_toc(j40__toc *toc) {
    j40__free(toc.sections);
    toc.sections = null;
}

////////////////////////////////////////////////////////////////////////////////
// DCT

// this is more or less a direct translation of mcos2/3 algorithms described in:
// Perera, S. M., & Liu, J. (2018). Lowest Complexity Self-Recursive Radix-2 DCT II/III Algorithms.
// SIAM Journal on Matrix Analysis and Applications, 39(2), 664--682.

// [(1<<n) + k] = 1/(2 cos((k+0.5)/2^(n+1) pi)) for n >= 1 and 0 <= k < 2^n
static immutable float[256] J40__HALF_SECANTS = 
[
    0, 0, // unused
    0.54119610f, 1.30656296f, // n=1 for DCT-4
    0.50979558f, 0.60134489f, 0.89997622f, 2.56291545f, // n=2 for DCT-8
    // n=3 for DCT-16
    0.50241929f, 0.52249861f, 0.56694403f, 0.64682178f, 0.78815462f, 1.06067769f, 1.72244710f, 5.10114862f,
    // n=4 for DCT-32
    0.50060300f, 0.50547096f, 0.51544731f, 0.53104259f, 0.55310390f, 0.58293497f, 0.62250412f, 0.67480834f,
    0.74453627f, 0.83934965f, 0.97256824f, 1.16943993f, 1.48416462f, 2.05778101f, 3.40760842f, 10.1900081f,
    // n=5 for DCT-64
    0.50015064f, 0.50135845f, 0.50378873f, 0.50747117f, 0.51245148f, 0.51879271f, 0.52657732f, 0.53590982f,
    0.54692044f, 0.55976981f, 0.57465518f, 0.59181854f, 0.61155735f, 0.63423894f, 0.66031981f, 0.69037213f,
    0.72512052f, 0.76549416f, 0.81270209f, 0.86834472f, 0.93458360f, 1.01440826f, 1.11207162f, 1.23383274f,
    1.38929396f, 1.59397228f, 1.87467598f, 2.28205007f, 2.92462843f, 4.08461108f, 6.79675071f, 20.3738782f,
    // n=6 for DCT-128
    0.50003765f, 0.50033904f, 0.50094272f, 0.50185052f, 0.50306519f, 0.50459044f, 0.50643095f, 0.50859242f,
    0.51108159f, 0.51390633f, 0.51707566f, 0.52059987f, 0.52449054f, 0.52876071f, 0.53342493f, 0.53849944f,
    0.54400225f, 0.54995337f, 0.55637499f, 0.56329167f, 0.57073059f, 0.57872189f, 0.58729894f, 0.59649876f,
    0.60636246f, 0.61693573f, 0.62826943f, 0.64042034f, 0.65345190f, 0.66743520f, 0.68245013f, 0.69858665f,
    0.71594645f, 0.73464482f, 0.75481294f, 0.77660066f, 0.80017990f, 0.82574877f, 0.85353675f, 0.88381100f,
    0.91688445f, 0.95312587f, 0.99297296f, 1.03694904f, 1.08568506f, 1.13994868f, 1.20068326f, 1.26906117f,
    1.34655763f, 1.43505509f, 1.53699410f, 1.65559652f, 1.79520522f, 1.96181785f, 2.16395782f, 2.41416000f,
    2.73164503f, 3.14746219f, 3.71524274f, 4.53629094f, 5.82768838f, 8.15384860f, 13.5842903f, 40.7446881f,
    // n=7 for DCT-256
    0.50000941f, 0.50008472f, 0.50023540f, 0.50046156f, 0.50076337f, 0.50114106f, 0.50159492f, 0.50212529f,
    0.50273257f, 0.50341722f, 0.50417977f, 0.50502081f, 0.50594098f, 0.50694099f, 0.50802161f, 0.50918370f,
    0.51042817f, 0.51175599f, 0.51316821f, 0.51466598f, 0.51625048f, 0.51792302f, 0.51968494f, 0.52153769f,
    0.52348283f, 0.52552196f, 0.52765682f, 0.52988922f, 0.53222108f, 0.53465442f, 0.53719139f, 0.53983424f,
    0.54258533f, 0.54544717f, 0.54842239f, 0.55151375f, 0.55472418f, 0.55805673f, 0.56151465f, 0.56510131f,
    0.56882030f, 0.57267538f, 0.57667051f, 0.58080985f, 0.58509780f, 0.58953898f, 0.59413825f, 0.59890075f,
    0.60383188f, 0.60893736f, 0.61422320f, 0.61969575f, 0.62536172f, 0.63122819f, 0.63730265f, 0.64359303f,
    0.65010770f, 0.65685553f, 0.66384594f, 0.67108889f, 0.67859495f, 0.68637535f, 0.69444203f, 0.70280766f,
    0.71148577f, 0.72049072f, 0.72983786f, 0.73954355f, 0.74962527f, 0.76010172f, 0.77099290f, 0.78232026f,
    0.79410679f, 0.80637720f, 0.81915807f, 0.83247799f, 0.84636782f, 0.86086085f, 0.87599311f, 0.89180358f,
    0.90833456f, 0.92563200f, 0.94374590f, 0.96273078f, 0.98264619f, 1.00355728f, 1.02553551f, 1.04865941f,
    1.07301549f, 1.09869926f, 1.12581641f, 1.15448427f, 1.18483336f, 1.21700940f, 1.25117548f, 1.28751481f,
    1.32623388f, 1.36756626f, 1.41177723f, 1.45916930f, 1.51008903f, 1.56493528f, 1.62416951f, 1.68832855f,
    1.75804061f, 1.83404561f, 1.91722116f, 2.00861611f, 2.10949453f, 2.22139378f, 2.34620266f, 2.48626791f,
    2.64454188f, 2.82479140f, 3.03189945f, 3.27231159f, 3.55471533f, 3.89110779f, 4.29853753f, 4.80207601f,
    5.44016622f, 6.27490841f, 7.41356676f, 9.05875145f, 11.6446273f, 16.3000231f, 27.1639777f, 81.4878422f,
];

// TODO spec bug: ScaleF doesn't match with the current libjxl! it turns out that this is actually
// a set of factors for the Arai, Agui, Nakajima DCT & IDCT algorithm, which was only used in
// older versions of libjxl (both the current libjxl and J40 currently uses Perera-Liu) and
// not even a resampling algorithm to begin with.
//
// [(1<<N) + k] = 1 / (cos(k/2^(4+N) pi) * cos(k/2^(3+N) pi) * cos(k/2^(2+N) pi) * 2^N)
//                for N >= 1 and 0 <= k < 2^N
static immutable float[64] J40__LF2LLF_SCALES = 
[
    0, // unused
    1.00000000f, // N=1, n=8
    0.50000000f, 0.55446868f, // N=2, n=16
    0.25000000f, 0.25644002f, 0.27723434f, 0.31763984f, // N=4, n=32
    // N=8, n=64
    0.12500000f, 0.12579419f, 0.12822001f, 0.13241272f, 0.13861717f, 0.14722207f, 0.15881992f, 0.17431123f,
    // N=16, n=128
    0.06250000f, 0.06259894f, 0.06289709f, 0.06339849f, 0.06411001f, 0.06504154f, 0.06620636f, 0.06762155f,
    0.06930858f, 0.07129412f, 0.07361103f, 0.07629973f, 0.07940996f, 0.08300316f, 0.08715562f, 0.09196277f,
    // N=32, n=256
    0.03125000f, 0.03126236f, 0.03129947f, 0.03136146f, 0.03144855f, 0.03156101f, 0.03169925f, 0.03186372f,
    0.03205500f, 0.03227376f, 0.03252077f, 0.03279691f, 0.03310318f, 0.03344071f, 0.03381077f, 0.03421478f,
    0.03465429f, 0.03513107f, 0.03564706f, 0.03620441f, 0.03680552f, 0.03745302f, 0.03814986f, 0.03889931f,
    0.03970498f, 0.04057091f, 0.04150158f, 0.04250201f, 0.04357781f, 0.04473525f, 0.04598138f, 0.04732417f,
];

enum float J40__SQRT2 = 1.4142135623730951f;



void j40__forward_dct_core(
    float* out_, float* in_, int t, int rep1, int rep2,
    void function(float* out_, float* in_, int t, int rep1, int rep2) nothrow @nogc half_forward_dct) 
{
    int r1, r2, i, N = 1 << t, stride = rep1 * rep2;

    // out[0..N) = W^c_N H_N in[0..N)
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2)
    {
        for (i = 0; i < N / 2; ++i) 
        {
            float mult = J40__HALF_SECANTS[N / 2 + i];
            for (r2 = 0; r2 < rep2; ++r2) 
            {
                float x = in_[(i) * stride + r1 + r2], 
                      y = in_[(N - i - 1) * stride + r1 + r2];
                in_[(i) * stride + r1 + r2] = x + y;
                in_[(N / 2 + i) * stride + r1 + r2] = (x - y) * mult;
            }
        }
    }

    // in[0..N/2) = mcos2(out[0..N/2), N/2)
    // in[N/2..N) = mcos2(out[N/2..N), N/2)
    half_forward_dct(in_, out_, t - 1, rep1, rep2);
    half_forward_dct(in_ + N / 2 * stride, out_ + N / 2 * stride, t - 1, rep1, rep2);

    // out[0,2..N) = in[0..N/2)
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2)
        for (i = 0; i < N / 2; ++i) 
            for (r2 = 0; r2 < rep2; ++r2)
            {
                out_[(i * 2) * stride + r1 + r2] = in_[(i) * stride + r1 + r2];
            }

    // out[1,3..N) = B_(N/2) in[N/2..N)
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2) 
    {
        for (r2 = 0; r2 < rep2; ++r2) 
        {
            out_[(1) * stride + r1 + r2] = J40__SQRT2 * in_[(N / 2) * stride + r1 + r2] + in_[(N / 2 + 1) * stride + r1 + r2];
        }
        for (i = 1; i < N / 2 - 1; ++i) 
        {
            for (r2 = 0; r2 < rep2; ++r2)
            {
                out_[(i * 2 + 1) * stride + r1 + r2] = in_[(N / 2 + i) * stride + r1 + r2] + in_[(N / 2 + i + 1) * stride + r1 + r2];
            }
        }
        for (r2 = 0; r2 < rep2; ++r2)
        {
            out_[(N - 1) * stride + r1 + r2] = in_[(N - 1) * stride + r1 + r2];
        }
    }
}


void j40__inverse_dct_core(
    float* out_, float* in_, int t, int rep1, int rep2,
    void function(float* out_, float* in_, int t, int rep1, int rep2) nothrow @nogc half_inverse_dct) 
{
    int r1, r2, i, N = 1 << t, stride = rep1 * rep2;

    // out[0..N/2) = in[0,2..N)
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2) 
    {
        for (i = 0; i < N / 2; ++i) {
            for (r2 = 0; r2 < rep2; ++r2)
            {
                out_[(i) * stride + r1 + r2] = in_[(i * 2) * stride + r1 + r2];
            }
        }
    }

    // out[N/2..N) = (B_(N/2))^T in[1,3..N)
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2) 
    {
        for (r2 = 0; r2 < rep2; ++r2)
        {
            out_[(N / 2) * stride + r1 + r2] = J40__SQRT2 * in_[(1) * stride + r1 + r2];
        }
        for (i = 1; i < N / 2; ++i) 
        {
            for (r2 = 0; r2 < rep2; ++r2)
            {
                out_[(N / 2 + i) * stride + r1 + r2] = in_[(i * 2 - 1) * stride + r1 + r2] + in_[(i * 2 + 1) * stride + r1 + r2];
            }
        }
    }

    // in[0..N/2) = mcos3(out[0..N/2), N/2)
    // in[N/2..N) = mcos3(out[N/2..N), N/2)
    half_inverse_dct(in_, out_, t - 1, rep1, rep2);
    half_inverse_dct(in_ + N / 2 * stride, out_ + N / 2 * stride, t - 1, rep1, rep2);

    // out[0..N) = (H_N)^T W^c_N in[0..N)
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2)
    {
        for (i = 0; i < N / 2; ++i) 
        {
            float mult = J40__HALF_SECANTS[N / 2 + i];
            for (r2 = 0; r2 < rep2; ++r2) 
            {
                float x = in_[(i) * stride + r1 + r2];
                float y = in_[(N / 2 + i) * stride + r1 + r2];
                // this might look wasteful, but modern compilers can optimize them into FMA
                // which can be actually faster than a single multiplication (TODO verify this)
                
                out_[(i) * stride + r1 + r2]         = x + y * mult;
                out_[(N - i - 1) * stride + r1 + r2] = x - y * mult;
            }
        }
    }
}

void j40__dct2(float* out_, float* in_, int t, int rep1, int rep2) {
    int r1, r2, stride = rep1 * rep2;
    assert(t == 1);
    for (r1 = 0; r1 < rep1 * rep2; r1 += rep2)
        for (r2 = 0; r2 < rep2; ++r2) 
        {
            float x = in_[(0) * stride + r1 + r2], 
                  y = in_[(1) * stride + r1 + r2];
            out_[(0) * stride + r1 + r2] = x + y;
            out_[(1) * stride + r1 + r2] = x - y;
        }
}

void j40__forward_dct4(float* out_, float* in_, int t, int rep1, int rep2) 
{
    assert(t == 2);
    j40__forward_dct_core(out_, in_, 2, rep1, rep2, &j40__dct2);
}

void j40__forward_dct_recur(float* out_, float* in_, int t, int rep1, int rep2) 
{
    if (t < 4) 
    {
        assert(t == 3);
        j40__forward_dct_core(out_, in_, 3, rep1, rep2, &j40__forward_dct4);
    } else {
        j40__forward_dct_core(out_, in_, t, rep1, rep2, &j40__forward_dct_recur);
    }
}

void j40__forward_dct_recur_x8(float* out_, float* in_, int t, int rep1, int rep2) {
    assert(rep2 == 8);
    if (t < 4) {
        assert(t == 3);
        j40__forward_dct_core(out_, in_, 3, rep1, 8, &j40__forward_dct4);
    } else {
        j40__forward_dct_core(out_, in_, t, rep1, 8, &j40__forward_dct_recur_x8);
    }
}

// this omits the final division by (1 << t)!
void j40__forward_dct_unscaled(float* out_, float* in_, int t, int rep) 
{
    if (t <= 0) 
    {
        memcpy(out_, in_, float.sizeof *cast(size_t) rep);
    } 
    else if (rep % 8 == 0) 
    {
        if (t == 1) j40__dct2(out_, in_, 1, rep / 8, 8);
        else if (t == 2) j40__forward_dct4(out_, in_, 2, rep / 8, 8);
        else j40__forward_dct_recur_x8(out_, in_, t, rep / 8, 8);
    } 
    else 
    {
        if (t == 1) j40__dct2(out_, in_, 1, rep, 1);
        else if (t == 2) j40__forward_dct4(out_, in_, 2, rep, 1);
        else j40__forward_dct_recur(out_, in_, t, rep, 1);
    }
}

void j40__forward_dct_unscaled_view(j40__view_f32 *outv, j40__view_f32 *inv) 
{
    j40__adapt_view_f32(outv, inv.logw, inv.logh);
    j40__forward_dct_unscaled(outv.ptr_, inv.ptr_, inv.logh, 1 << inv.logw);
}

void j40__inverse_dct4(float* out_, float* in_, int t, int rep1, int rep2) 
{
    assert(t == 2);
    j40__inverse_dct_core(out_, in_, 2, rep1, rep2, &j40__dct2);
}

void j40__inverse_dct_recur(float* out_, float* in_, int t, int rep1, int rep2) 
{
    if (t < 4) 
    {
        assert(t == 3);
        j40__inverse_dct_core(out_, in_, 3, rep1, rep2, &j40__inverse_dct4);
    } else {
        j40__inverse_dct_core(out_, in_, t, rep1, rep2, &j40__inverse_dct_recur);
    }
}

void j40__inverse_dct_recur_x8(float* out_, float* in_, int t, int rep1, int rep2) 
{
    assert(rep2 == 8);
    if (t < 4) 
    {
        assert(t == 3);
        j40__inverse_dct_core(out_, in_, 3, rep1, 8, &j40__inverse_dct4);
    } else {
        j40__inverse_dct_core(out_, in_, t, rep1, 8, &j40__inverse_dct_recur_x8);
    }
}

void j40__inverse_dct(float* out_, float* in_, int t, int rep) 
{
    if (t <= 0) {
        memcpy(out_, in_, float.sizeof * cast(size_t) rep);
    } else if (rep % 8 == 0) {
        if (t == 1) j40__dct2(out_, in_, 1, rep / 8, 8);
        else if (t == 2) j40__inverse_dct4(out_, in_, 2, rep / 8, 8);
        else j40__inverse_dct_recur_x8(out_, in_, t, rep / 8, 8);
    } else {
        if (t == 1) j40__dct2(out_, in_, 1, rep, 1);
        else if (t == 2) j40__inverse_dct4(out_, in_, 2, rep, 1);
        else j40__inverse_dct_recur(out_, in_, t, rep, 1);
    }
}

void j40__inverse_dct_view(j40__view_f32 *outv, j40__view_f32 *inv) 
{
    j40__adapt_view_f32(outv, inv.logw, inv.logh);
    j40__inverse_dct(outv.ptr_, inv.ptr_, inv.logh, 1 << inv.logw);
}


void j40__forward_dct2d_scaled_for_llf(float* buf, float* scratch, int log_rows, int log_columns) 
{
    j40__view_f32 bufv = j40__make_view_f32(log_columns, log_rows, buf);
    j40__view_f32 scratchv = j40__make_view_f32(log_columns, log_rows, scratch);
    float *p;
    int x, y;

    j40__forward_dct_unscaled_view(&scratchv, &bufv);
    j40__transpose_view_f32(&bufv, scratchv);
    j40__forward_dct_unscaled_view(&scratchv, &bufv);
    // TODO spec bug (I.6.5): the pseudocode only works correctly when C > R;
    // the condition itself can be eliminated by inlining DCT_2D though

    for (y = 0; y < (1 << (scratchv).logh); ++y)
    {
        for (x = 0; x < (1 << (scratchv).logw) && 

             // weird comma use, this exp needs to be always true, and assign
             ((null != (p = (scratchv).ptr_ + (y << (scratchv).logw | x))) || true); ++x)
        {
            // hopefully compiler will factor the second multiplication out of the inner loop (TODO verify this)
            *p *= J40__LF2LLF_SCALES[(1 << scratchv.logw) + x] * J40__LF2LLF_SCALES[(1 << scratchv.logh) + y];
        }
    }

    // TODO spec improvement (I.6.3 note): given the pseudocode, it might be better to
    // state that the DCT result *always* has C <= R, transposing as necessary.
    if (log_columns > log_rows) 
    {
        j40__transpose_view_f32(&bufv, scratchv);
    } 
    else 
    {
        j40__copy_view_f32(&bufv, scratchv);
    }
    assert(bufv.logw == j40__max32(log_columns, log_rows));
    assert(bufv.logh == j40__min32(log_columns, log_rows));
}

void j40__inverse_dct2d(float* buf, float* scratch, int log_rows, int log_columns) 
{
    j40__view_f32 bufv;
    j40__view_f32 scratchv = j40__make_view_f32(log_columns, log_rows, scratch);

    if (log_columns > log_rows) {
        // TODO spec improvement: coefficients start being transposed, note this as well
        bufv = j40__make_view_f32(log_columns, log_rows, buf);
        j40__transpose_view_f32(&scratchv, bufv);
    } else {
        bufv = j40__make_view_f32(log_rows, log_columns, buf);
        j40__copy_view_f32(&scratchv, bufv);
    }
    j40__inverse_dct_view(&bufv, &scratchv);
    j40__transpose_view_f32(&scratchv, bufv);
    j40__inverse_dct_view(&bufv, &scratchv);
    assert(bufv.logw == log_columns && bufv.logh == log_rows);
}

// a single iteration of AuxIDCT2x2
void j40__aux_inverse_dct11(float *out_, float *in_, int x, int y, int S2) 
{
    int p = y * 8 + x, q = (y * 2) * 8 + (x * 2);
    float c00 = in_[p], 
          c01 = in_[p + S2], 
          c10 = in_[p + S2 * 8], 
          c11 = in_[p + S2 * 9];
    out_[q + 0] = c00 + c01 + c10 + c11; // r00
    out_[q + 1] = c00 + c01 - c10 - c11; // r01
    out_[q + 8] = c00 - c01 + c10 - c11; // r10
    out_[q + 9] = c00 - c01 - c10 + c11; // r11
}

void j40__inverse_dct11(float *buf) 
{
    float[64] scratch;
    int x, y;

    // TODO spec issue: only the "top-left" SxS cells, not "top"
    j40__aux_inverse_dct11(buf, buf, 0, 0, 1); // updates buf[(0..1)*8+(0..1)]
    // updates scratch[(0..3)*8+(0..3)], copying other elements from buf in verbatim
    memcpy(scratch.ptr, buf, float.sizeof * 64);
    for (y = 0; y < 2; ++y) 
        for (x = 0; x < 2; ++x) 
            j40__aux_inverse_dct11(scratch.ptr, buf, x, y, 2);

    // updates the entire buf
    for (y = 0; y < 4; ++y) 
        for (x = 0; x < 4; ++x) 
            j40__aux_inverse_dct11(buf, scratch.ptr, x, y, 4);
}

void j40__inverse_dct22(float *buf) 
{
    float[64] scratch;
    int x, y;

    j40__aux_inverse_dct11(buf, buf, 0, 0, 1);
    // after the top-left inverse DCT2x2, four 4x4 submatrices are formed and IDCTed individually.
    // IDCT itself requires transposition and the final matrices are stitched in a different way,
    // but it turns out that IDCT can be done in place, only requiring the final stitching.
    //
    // input                        after transposition          output
    // a1 a2 b1 b2 c1 c2 d1 d2      a1 a3 e1 e3 i1 i3 m1 m3      a1 e1 i1 m1 a2 e2 i2 m2
    // a3 a4 b3 b4 c3 c4 d3 d4      a2 a4 e2 e4 i2 i4 m2 m4      b1 f1 j1 n1 b2 f2 j2 n2
    // e1 e2 f1 f2 g1 g2 h1 h2      b1 b3 f1 f3 j1 j3 n1 n3      c1 g1 k1 o1 c2 g2 k2 o2
    // e3 e4 f3 f4 g3 g4 h3 h4 --. b2 b4 f2 f4 j2 j4 n2 n4 --. d1 k1 l1 p1 d2 k2 l2 p2
    // i1 i2 j1 j2 k1 k2 l1 l2      c1 c3 g1 g3 k1 k3 o1 o3      a3 e3 i3 m3 a4 e4 i4 m4
    // i3 i4 j3 j4 k3 k4 l3 l4      c2 c4 g2 g4 k2 k4 o2 o4      b3 f3 j3 n3 b4 f4 j4 n4
    // m1 m2 n1 n2 o1 o2 p1 p2      d1 d3 h1 h3 l1 l3 p1 p3      c3 g3 k3 o3 c4 g4 k4 o4
    // m3 m4 n3 n4 o3 o4 p3 p4      d2 d4 h2 h4 l2 l4 p2 p4      d3 k3 l3 p3 d4 k4 l4 p4
    //
    // TODO spec issue: notationally `sample` is a *4-dimensional* array, which is not very clear
    j40__inverse_dct(scratch.ptr, buf, 2, 16); // columnar IDCT for a#-m#, b#-n#, c#-o# and d#-p#
    for (y = 0; y < 8; ++y) for (x = 0; x < 8; ++x) buf[x * 8 + y] = scratch[y * 8 + x];
    j40__inverse_dct(scratch.ptr, buf, 2, 16); // columnar IDCT for a#-d#, e#-h#, i#-l# and m#-p#
    for (y = 0; y < 4; ++y) for (x = 0; x < 4; ++x) 
    {
        buf[y * 8 + x] = scratch[(y * 2) * 8 + (x * 2)];
        buf[y * 8 + (x + 4)] = scratch[(y * 2 + 1) * 8 + (x * 2)];
        buf[(y + 4) * 8 + x] = scratch[(y * 2) * 8 + (x * 2 + 1)];
        buf[(y + 4) * 8 + (x + 4)] = scratch[(y * 2 + 1) * 8 + (x * 2 + 1)];
    }
}

void j40__inverse_hornuss(float *buf) 
{
    float[64] scratch;
    int x, y, ix, iy;
    memcpy(scratch.ptr, buf, float.sizeof * 64);
    j40__aux_inverse_dct11(scratch.ptr, buf, 0, 0, 1); // updates scratch[(0..1)*8+(0..1)]
    for (y = 0; y < 2; ++y) for (x = 0; x < 2; ++x) 
    {
        int pos00 = y * 8 + x, pos11 = (y + 2) * 8 + (x + 2);
        float[4] rsum = [0.0f, 0, 0, 0];
        float sample11;
        for (iy = 0; iy < 4; ++iy) 
        {
            for (ix = 0; ix < 4; ++ix) 
            {
                rsum[ix] += scratch[(y + iy * 2) * 8 + (x + ix * 2)];
            }
        }
        // conceptually (SUM rsum[i]) = residual_sum + coefficients(x, y) in the spec
        sample11 = scratch[pos00] - (rsum[0] + rsum[1] + rsum[2] + rsum[3] - scratch[pos00]) * 0.0625f;
        scratch[pos00] = scratch[pos11];
        scratch[pos11] = 0.0f;
        for (iy = 0; iy < 4; ++iy) for (ix = 0; ix < 4; ++ix) 
        {
            buf[(4 * y + iy) * 8 + (4 * x + ix)] = scratch[(y + iy * 2) * 8 + (x + ix * 2)] + sample11;
        }
    }
}

void j40__inverse_dct32(float *buf) 
{
    float[64] scratch;
    float tmp;
    j40__view_f32 bufv = j40__make_view_f32(3, 3, buf);
    j40__view_f32 scratchv = j40__make_view_f32(3, 3, scratch.ptr);

    // coefficients form two 4 rows x 8 columns matrices from even and odd rows;
    // note that this is NOT 8 rows x 4 columns, because of transposition
    // TODO spec issue: inconsistent naming between coeffs_8x4 and coeffs_4x8
    tmp = *J40__AT(bufv, 0, 0) + *J40__AT(bufv, 0, 1);
    *J40__AT(bufv, 0, 1) = *J40__AT(bufv, 0, 0) - *J40__AT(bufv, 0, 1);
    *J40__AT(bufv, 0, 0) = tmp;
    j40__reshape_view_f32(&bufv, 4, 2);
    j40__inverse_dct_view(&scratchv, &bufv);
    j40__reshape_view_f32(&scratchv, 3, 3);
    j40__transpose_view_f32(&bufv, scratchv);
    j40__inverse_dct_view(&scratchv, &bufv);
    j40__oddeven_columns_to_halves_f32(&bufv, scratchv);
    assert(bufv.logw == 3 && bufv.logh == 3);
}

void j40__inverse_dct23(float *buf) 
{
    float[64] scratch;
    j40__view_f32 bufv     = j40__make_view_f32(3, 3, buf);
    j40__view_f32 scratchv = j40__make_view_f32(3, 3, scratch.ptr);

    // coefficients form two 4 rows x 8 columns matrices from even and odd rows
    j40__copy_view_f32(&scratchv, bufv);
    *J40__AT(scratchv, 0, 0) = *J40__AT(bufv, 0, 0) + *J40__AT(bufv, 0, 1);
    *J40__AT(scratchv, 0, 1) = *J40__AT(bufv, 0, 0) - *J40__AT(bufv, 0, 1);
    j40__transpose_view_f32(&bufv, scratchv);
    j40__inverse_dct_view(&scratchv, &bufv);
    j40__transpose_view_f32(&bufv, scratchv);
    j40__reshape_view_f32(&bufv, 4, 2);
    j40__inverse_dct_view(&scratchv, &bufv);
    j40__reshape_view_f32(&scratchv, 3, 3);
    j40__oddeven_rows_to_halves_f32(&bufv, scratchv);
    assert(bufv.logw == 3 && bufv.logh == 3);
}

// TODO spec issue: the input is a 4x4 matrix but indexed like a 1-dimensional array
void j40__inverse_afv22(float* out_, float* in_) 
{
    // AFVBasis in the specification, but transposed
    static immutable float[256] AFV_BASIS = 
    [ 
         0.25000000f,  0.87690293f,  0.00000000f,  0.00000000f,
         0.00000000f, -0.41053776f,  0.00000000f,  0.00000000f,
         0.00000000f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.00000000f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.25000000f,  0.22065181f,  0.00000000f,  0.00000000f,
        -0.70710678f,  0.62354854f,  0.00000000f,  0.00000000f,
         0.00000000f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.00000000f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.25000000f, -0.10140050f,  0.40670076f, -0.21255748f,
         0.00000000f, -0.06435072f, -0.45175566f, -0.30468475f,
         0.30179295f,  0.40824829f,  0.17478670f, -0.21105601f,
        -0.14266085f, -0.13813540f, -0.17437603f,  0.11354987f,
         0.25000000f, -0.10140050f,  0.44444817f,  0.30854971f,
         0.00000000f, -0.06435072f,  0.15854504f,  0.51126161f,
         0.25792363f,  0.00000000f,  0.08126112f,  0.18567181f,
        -0.34164468f,  0.33022826f,  0.07027907f, -0.07417505f,
         0.25000000f,  0.22065181f,  0.00000000f,  0.00000000f,
         0.70710678f,  0.62354854f,  0.00000000f,  0.00000000f,
         0.00000000f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.00000000f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.25000000f, -0.10140050f,  0.00000000f,  0.47067023f,
         0.00000000f, -0.06435072f, -0.04038515f,  0.00000000f,
         0.16272340f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.73674975f,  0.08755115f, -0.29210266f,  0.19402893f,
         0.25000000f, -0.10140050f,  0.19574399f, -0.16212052f,
         0.00000000f, -0.06435072f,  0.00741823f, -0.29048013f,
         0.09520023f,  0.00000000f, -0.36753980f,  0.49215859f,
         0.24627108f, -0.07946707f,  0.36238173f, -0.43519050f,
         0.25000000f, -0.10140050f,  0.29291001f,  0.00000000f,
         0.00000000f, -0.06435072f,  0.39351034f, -0.06578702f,
         0.00000000f, -0.40824829f, -0.30788221f, -0.38525014f,
        -0.08574019f, -0.46133749f,  0.00000000f,  0.21918685f,
         0.25000000f, -0.10140050f, -0.40670076f, -0.21255748f,
         0.00000000f, -0.06435072f, -0.45175566f,  0.30468475f,
         0.30179295f, -0.40824829f, -0.17478670f,  0.21105601f,
        -0.14266085f, -0.13813540f, -0.17437603f,  0.11354987f,
         0.25000000f, -0.10140050f, -0.19574399f, -0.16212052f,
         0.00000000f, -0.06435072f,  0.00741823f,  0.29048013f,
         0.09520023f,  0.00000000f,  0.36753980f, -0.49215859f,
         0.24627108f, -0.07946707f,  0.36238173f, -0.43519050f,
         0.25000000f, -0.10140050f,  0.00000000f, -0.47067023f,
         0.00000000f, -0.06435072f,  0.11074166f,  0.00000000f,
        -0.16272340f,  0.00000000f,  0.00000000f,  0.00000000f,
         0.14883399f,  0.49724647f,  0.29210266f,  0.55504438f,
         0.25000000f, -0.10140050f,  0.11379074f, -0.14642919f,
         0.00000000f, -0.06435072f,  0.08298163f, -0.23889774f,
        -0.35312385f, -0.40824829f,  0.48266891f,  0.17419413f,
        -0.04768680f,  0.12538059f, -0.43266080f, -0.25468277f,
         0.25000000f, -0.10140050f, -0.44444817f,  0.30854971f,
         0.00000000f, -0.06435072f,  0.15854504f, -0.51126161f,
         0.25792363f,  0.00000000f, -0.08126112f, -0.18567181f,
        -0.34164468f,  0.33022826f,  0.07027907f, -0.07417505f,
         0.25000000f, -0.10140050f, -0.29291001f,  0.00000000f,
         0.00000000f, -0.06435072f,  0.39351034f,  0.06578702f,
         0.00000000f,  0.40824829f,  0.30788221f,  0.38525014f,
        -0.08574019f, -0.46133749f,  0.00000000f,  0.21918685f,
         0.25000000f, -0.10140050f, -0.11379074f, -0.14642919f,
         0.00000000f, -0.06435072f,  0.08298163f,  0.23889774f,
        -0.35312385f,  0.40824829f, -0.48266891f, -0.17419413f,
        -0.04768680f,  0.12538059f, -0.43266080f, -0.25468277f,
         0.25000000f, -0.10140050f,  0.00000000f,  0.42511496f,
         0.00000000f, -0.06435072f, -0.45175566f,  0.00000000f,
        -0.60358590f,  0.00000000f,  0.00000000f,  0.00000000f,
        -0.14266085f, -0.13813540f,  0.34875205f,  0.11354987f,
    ];

    int i, j;
    for (i = 0; i < 16; ++i) 
    {
        float sum = 0.0f;
        for (j = 0; j < 16; ++j) 
        {
            sum += in_[j] * AFV_BASIS[i * 16 + j];
        }
        out_[i] = sum;
    }
}

void j40__inverse_afv(float *buf, int flipx, int flipy) 
{
    // input          flipx/y=0/0     flipx/y=1/0     flipx/y=0/1     flipx/y=1/1
    //  _______       +-----+-----+   +-----+-----+   +-----------+   +-----------+
    // |_|_|_|_|      |'    |     |   |     |    '|   |           |   |           |
    // |_|_|_|_| --. |AFV22|DCT22|   |DCT22|AFV22|   |   DCT23   |   |   DCT23   |
    // |_|_|_|_|      +-----+-----+   +-----+-----+   +-----+-----+   +-----+-----+
    // |_|_|_|_|      |   DCT23   |   |   DCT23   |   |AFV22|DCT22|   |DCT22|AFV22|
    //                |           |   |           |   |.    |     |   |     |    .|
    // (2x2 each)     +-----------+   +-----------+   +-----+-----+   +-----+-----+
    //
    // coefficients are divided by 16 2x2 blocks, where two top coefficients are for AFV22
    // and DCT22 respectively and two bottom coefficients are for DCT23.
    // all three corresponding DC coefficients are in the top-left block and handled specially.
    // AFV22 samples are then flipped so that the top-left cell is moved to the corner (dots above).
    //
    // TODO spec issue: identifiers have `*` in place of `x`

    float[64] scratch;
    // buf23/buf32 etc. refer to the same memory region; numbers refer to the supposed dimensions
    float* bufafv = buf, 
           buf22  = buf + 16, 
           buf23  = buf + 32, 
           buf32  = buf23;
    float* scratchafv = scratch.ptr, 
           scratch22  = scratch.ptr + 16, 
           scratch23  = scratch.ptr + 32, 
           scratch32 = scratch23;
    int x, y;

    assert(flipx == !!flipx && flipy == !!flipy);

    for (y = 0; y < 8; y += 2) for (x = 0; x < 8; ++x) 
    {
        // AFV22 coefficients to scratch[0..16), DCT22 coefficients to scratch[16..32)
        scratch[(x % 2) * 16 + (y / 2) * 4 + (x / 2)] = buf[y * 8 + x];
    }
    for (y = 1; y < 8; y += 2) for (x = 0; x < 8; ++x) 
    {
        // DCT23 coefficients to scratch[32..64) = scratch32[0..32), after transposition
        scratch32[x * 4 + (y / 2)] = buf[y * 8 + x];
    }
    scratchafv[0] = (buf[0] + buf[1] + buf[8]) * 4.0f;
    scratch22[0] = buf[0] - buf[1] + buf[8]; // TODO spec bug: x and y are swapped
    scratch32[0] = buf[0] - buf[8]; // TODO spec bug: x and y are swapped

    j40__inverse_afv22(bufafv, scratchafv);
    j40__inverse_dct(buf22, scratch22, 2, 4);
    j40__inverse_dct(buf32, scratch32, 3, 4);

    for (y = 0; y < 4; ++y) {
        for (x = 0; x < 4; ++x) scratchafv[y * 4 + x] = bufafv[y * 4 + x]; // AFV22, as is
        for (x = 0; x < 4; ++x) scratch22[x * 4 + y] = buf22[y * 4 + x]; // DCT22, transposed
    }
    for (y = 0; y < 8; ++y) {
        for (x = 0; x < 4; ++x) scratch23[x * 8 + y] = buf32[y * 4 + x]; // DCT23, transposed
    }

    j40__inverse_dct(buf22, scratch22, 2, 4);
    j40__inverse_dct(buf23, scratch23, 2, 8);
    memcpy(scratch.ptr + 16, buf + 16, float.sizeof * 48);

    for (y = 0; y < 4; ++y) {
        static immutable byte[4][2] FLIP_FOR_AFV = [[0, 1, 2, 3], [7, 6, 5, 4]];
        int afv22pos = FLIP_FOR_AFV[flipy][y] * 8;
        int dct22pos = (flipy * 4 + y) * 8 + (!flipx * 4);
        int dct23pos = (!flipy * 4 + y) * 8;
        for (x = 0; x < 4; ++x) buf[afv22pos + FLIP_FOR_AFV[flipx][x]] = scratchafv[y * 4 + x];
        for (x = 0; x < 4; ++x) buf[dct22pos + x] = scratch22[y * 4 + x];
        // TODO spec issue: samples_4x4 should be samples_4x8
        for (x = 0; x < 8; ++x) buf[dct23pos + x] = scratch23[y * 8 + x];
    }
}

////////////////////////////////////////////////////////////////////////////////
// LfGlobal: additional image features, HF block context, global tree, extra channels

j40_err j40__lf_global(j40__st *st) 
{
    j40__frame_st *f = st.frame;
    int sidx = 0;
    int i, j;

    if (f.has_patches) do { j40__set_error(st, J40__4("TODO: patches")); goto J40__ON_ERROR; } while (0);
    if (f.has_splines) do { j40__set_error(st, J40__4("TODO: splines")); goto J40__ON_ERROR; } while (0);
    if (f.has_noise) do { j40__set_error(st, J40__4("TODO: noise")); goto J40__ON_ERROR; } while (0);

    if (!j40__u(st, 1)) { // LfChannelDequantization.all_default
        // TODO spec bug: missing division by 128
        for (i = 0; i < 3; ++i) f.m_lf_scaled[i] = j40__f16(st) / 128.0f;
    }

    if (!f.is_modular) {
        f.global_scale = j40__u32(st, 1, 11, 2049, 11, 4097, 12, 8193, 16);
        f.quant_lf = j40__u32(st, 16, 0, 1, 5, 1, 8, 1, 16);

        // HF block context
        if (j40__u(st, 1)) {
            static immutable ubyte[13*3] DEFAULT_BLKCTX = 
            [
                0, 1, 2, 2,  3,  3,  4,  5,  6,  6,  6,  6,  6,
                7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
                7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
            ];
            f.block_ctx_size = DEFAULT_BLKCTX.length;
            f.block_ctx_map = cast(ubyte*) j40__malloc(DEFAULT_BLKCTX.sizeof, ubyte.sizeof);
            
            memcpy(f.block_ctx_map, DEFAULT_BLKCTX.ptr, (DEFAULT_BLKCTX).sizeof);
            f.nb_qf_thr = f.nb_lf_thr[0] = f.nb_lf_thr[1] = f.nb_lf_thr[2] = 0; // SPEC is implicit
            f.nb_block_ctx = 15;
        } else {
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);
            f.block_ctx_size = 39; // SPEC not 27
            for (i = 0; i < 3; ++i) 
            {
                f.nb_lf_thr[i] = j40__u(st, 4);
                // TODO spec question: should this be sorted? (current code is okay with that)
                for (j = 0; j < f.nb_lf_thr[i]; ++j) 
                {
                    f.lf_thr[i][j] = cast(int) j40__unpack_signed64(j40__64u32(st, 0, 4, 16, 8, 272, 16, 65808, 32));
                }
                f.block_ctx_size *= f.nb_lf_thr[i] + 1; // SPEC is off by one
            }
            f.nb_qf_thr = j40__u(st, 4);
            // TODO spec bug: both qf_thr[i] and HfMul should be incremented
            for (i = 0; i < f.nb_qf_thr; ++i) f.qf_thr[i] = j40__u32(st, 0, 2, 4, 3, 12, 5, 44, 8) + 1;
            f.block_ctx_size *= f.nb_qf_thr + 1; // SPEC is off by one
            // block_ctx_size <= 39*15^4 and never overflows
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((f.block_ctx_size <= 39 * 64) == 0)) { j40__set_error(st, J40__4("hfbc")); goto J40__ON_ERROR; } } while (0); 
            do { if (J40_UNLIKELY(j40__cluster_map(st, f.block_ctx_size, 16, &f.nb_block_ctx, &f.block_ctx_map))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }

        if (!j40__u(st, 1)) { // LfChannelCorrelation.all_default
            f.inv_colour_factor = 1.0f / cast(float) j40__u32(st, 84, 0, 256, 0, 2, 8, 258, 16);
            f.base_corr_x = j40__f16(st);
            f.base_corr_b = j40__f16(st);
            f.x_factor_lf = j40__u(st, 8) - 127;
            f.b_factor_lf = j40__u(st, 8) - 127;
        }
    }

    // we need f.gmodular.num_channels for j40__tree
    do { if (J40_UNLIKELY(j40__init_modular_for_global(st, f.is_modular, f.do_ycbcr, f.log_upsampling, f.ec_log_upsampling, f.width, f.height, &f.gmodular))) { assert(st.err); goto J40__ON_ERROR; } } while (0);


    if (j40__u(st, 1)) { 
        int max_tree_size = j40__min32(1 << 22,
            1024 + j40__clamp_mul32(j40__clamp_mul32(f.width, f.height), f.gmodular.num_channels) / 16);
        do { if (J40_UNLIKELY(j40__tree(st, max_tree_size, &f.global_tree, &f.global_codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }

    if (f.gmodular.num_channels > 0) {
        do { if (J40_UNLIKELY(j40__modular_header(st, f.global_tree, &f.global_codespec, &f.gmodular))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__allocate_modular(st, &f.gmodular))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        if (f.width <= (1 << f.group_size_shift) && f.height <= (1 << f.group_size_shift)) {
            f.num_gm_channels = f.gmodular.num_channels;
        } else {
            f.num_gm_channels = f.gmodular.nb_meta_channels;
        }
        for (i = 0; i < f.num_gm_channels; ++i) {
            do { if (J40_UNLIKELY(j40__modular_channel(st, &f.gmodular, i, sidx))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
        do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &f.gmodular.code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    } else {
        f.num_gm_channels = 0;
    }

J40__ON_ERROR:
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// LfGroup: downsampled LF image (optionally smoothed), varblock information

struct j40__varblock
{
    int coeffoff_qfidx; // offset to coeffs (always a multiple of 64) | qf index (always < 16)
    union hfmul_t 
    {
        int m1; // HfMul - 1 during j40__hf_metadata, to avoid overflow at this stage
        float inv; // 1 / HfMul after j40__hf_metadata
    } 
    hfmul_t hfmul;
    // DctSelect is embedded in blocks
}

enum J40__COEFFS_ALIGN = 64;

struct j40__lf_group_st 
{
    long idx;

    int left, top;
    int width, height; // <= 8192
    int width8, height8; // <= 1024
    int width64, height64; // <= 128

    // contained group indices: [gidx + gstride * y, gidx + gstride * y + gcolumns) for each row
    long gidx, grows, gcolumns, gstride;

    j40__plane xfromy, bfromy; // width64 x height64 each
    j40__plane sharpness; // width8 x height8

    int nb_varblocks; // <= 2^20 (TODO spec issue: named nb_blocks)
    // bits 0..19: varblock index [0, nb_varblocks)
    // bits 20..24: DctSelect + 2, or 1 if not the top-left corner (0 is reserved for unused block)
    j40__plane blocks; // width8 x height8
    j40__varblock *varblocks; // [nb_varblocks]

    float*[3] llfcoeffs; // [width8*height8] each
    // TODO coeffs can be integers before dequantization
    float*[3] coeffs; // [width8*height8*64] each, aligned
    
    ubyte[3] coeffs_misalign;

    // precomputed lf_idx
    j40__plane lfindices; // [width8*height8]

    int loaded;
}

// out(x, y) = in(x, y) * mult (after type conversion)
void j40__dequant_lfP(int P)(const j40__plane *in_, float mult, j40__plane *out_) 
{
    int x, y;
    assert(in_.type == J40__PLANE_I!P && out_.type == J40__PLANE_F32);
    assert(in_.width <= out_.width && in_.height <= out_.height);
    for (y = 0; y < in_.height; ++y) 
    {
        const(j40__intP!P)* inpixels = J40__PIXELS!P(in_, y);
        float *outpixels = J40__F32_PIXELS(out_, y);
        for (x = 0; x < in_.width; ++x) 
            outpixels[x] = cast(float) inpixels[x] * mult;
    }
}

// plane(x, y) += # of lf_thr[i] s.t. in(x, y) > lf_thr[i]
void j40__add_thresholdsP(int P)(j40__plane *plane, 
                                 const(j40__plane)* in_, 
                                 const(int)* lf_thr, 
                                 int nb_lf_thr)
{
    int x, y, i;
    assert(in_.type == J40__PLANE_I!P && plane.type == J40__PLANE_U8);
    assert(in_.width <= plane.width && in_.height <= plane.height);
    for (y = 0; y < plane.height; ++y) {
        const(j40__intP!P)* inpixels = J40__PIXELS!P(in_, y);
        ubyte *pixels = J40__U8_PIXELS(plane, y);
        for (i = 0; i < nb_lf_thr; ++i) 
        {
            int threshold = lf_thr[i];
            for (x = 0; x < in_.width; ++x) 
            {
                pixels[x] = cast(ubyte) (pixels[x] + (inpixels[x] > threshold));
            }
        }
    }
}

void j40__dequant_lf(const(j40__plane)* in_, 
                     float mult, 
                     j40__plane *out_) 
{
    switch (in_.type) 
    {
    case J40__PLANE_I16: j40__dequant_lfP!16(in_, mult, out_); break;
    case J40__PLANE_I32: j40__dequant_lfP!32(in_, mult, out_); break;
    default: J40__UNREACHABLE();
    }
}

void j40__add_thresholds(j40__plane *plane, 
                         const(j40__plane)* in_, 
                         const int *lf_thr, 
                         int nb_lf_thr)
{
    switch (in_.type) {
    case J40__PLANE_I16: j40__add_thresholdsP!16(plane, in_, lf_thr, nb_lf_thr); break;
    case J40__PLANE_I32: j40__add_thresholdsP!32(plane, in_, lf_thr, nb_lf_thr); break;
    default: J40__UNREACHABLE();
    }
}

void j40__multiply_each_u8(j40__plane *plane, int mult) 
{
    int x, y;
    assert(plane.type == J40__PLANE_U8);
    for (y = 0; y < plane.height; ++y) 
    {
        ubyte *pixels = J40__U8_PIXELS(plane, y);
        for (x = 0; x < plane.width; ++x) 
            pixels[x] = cast(ubyte) (pixels[x] * mult);
    }
}

j40_err j40__smooth_lf(j40__st *st, 
                       j40__lf_group_st *gg, 
                       j40__plane[] lfquant) 
{
    assert(lfquant.length == 3);
    immutable float W0 = 0.05226273532324128f, 
                    W1 = 0.20345139757231578f, 
                    W2 = 0.0334829185968739f;

    j40__frame_st *f = st.frame;
    int ggw8 = gg.width8, 
        ggh8 = gg.height8;
    float *linebuf = null; 
    float*[3] nline;
    float*[3] line;
    float[3] inv_m_lf;
    int x, y, c;

    for (c = 0; c < 3; ++c) 
    {
        // TODO spec bug: missing 2^16 scaling
        inv_m_lf[c] = cast(float) (f.global_scale * f.quant_lf) / f.m_lf_scaled[c] / 65536.0f;
    }

    linebuf = cast(float*) j40__malloc(cast(size_t)(ggw8 * 6), float.sizeof);


    for (c = 0; c < 3; ++c) 
    {
        nline[c] = linebuf + (c + 3) * ggw8; // intentionally uninitialized
        line[c] = linebuf + c * ggw8; // row 0
        memcpy(line[c], J40__F32_PIXELS(&lfquant[c], 0), float.sizeof * cast(size_t) ggw8);
    }

    for (y = 1; y < ggh8 - 1; ++y) 
    {
        float*[3] outline;
        float*[3] sline;
        for (c = 0; c < 3; ++c) 
        {
            float *temp = nline[c];
            nline[c] = line[c];
            line[c] = temp;
            outline[c] = J40__F32_PIXELS(&lfquant[c], y);
            sline[c] = J40__F32_PIXELS(&lfquant[c], y + 1);
            memcpy(line[c], outline[c], float.sizeof * cast(size_t) ggw8);
        }
        for (x = 1; x < ggw8 - 1; ++x) 
        {
            float[3] wa, diff;
            float gap = 0.5f;
            for (c = 0; c < 3; ++c) {
                wa[c] =
                    (nline[c][x - 1] * W2 + nline[c][x] * W1 + nline[c][x + 1] * W2) +
                    ( line[c][x - 1] * W1 +  line[c][x] * W0 +  line[c][x + 1] * W1) +
                    (sline[c][x - 1] * W2 + sline[c][x] * W1 + sline[c][x + 1] * W2);
                diff[c] = fabsf(wa[c] - line[c][x]) * inv_m_lf[c];
                if (gap < diff[c]) 
                    gap = diff[c];
            }
            gap = j40__maxf(0.0f, 3.0f - 4.0f * gap);
            // TODO spec bug: s (sample) and wa (weighted average) are swapped in the final formula
            for (c = 0; c < 3; ++c) 
                outline[c][x] = (wa[c] - line[c][x]) * gap + line[c][x];
        }
    }

J40__ON_ERROR:
    j40__free(linebuf);
    return st.err;
}

j40_err j40__lf_quant(j40__st *st,
                      int extra_prec, 
                      j40__modular *m, 
                      j40__lf_group_st *gg, 
                      j40__plane[] outlfquant) 
{
    assert(outlfquant.length == 3);

    static immutable int[3] YXB2XYB = [1, 0, 2]; // TODO spec bug: this reordering is missing

    j40__frame_st *f = st.frame;
    int ggw8 = gg.width8, ggh8 = gg.height8;
    j40__plane*[3] channel; 
    j40__plane[3] lfquant; 
    j40__plane lfindices;
    int c;

    assert(j40__plane_all_equal_sized(m.channel, m.channel + 3));

    for (c = 0; c < 3; ++c)
    {
        do { if (J40_UNLIKELY(j40__init_plane(st, J40__PLANE_F32, ggw8, ggh8, 0, &lfquant[c]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
    do { if (J40_UNLIKELY(j40__init_plane(st, J40__PLANE_U8, ggw8, ggh8, J40__PLANE_CLEAR, &lfindices))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    // extract LfQuant from m and populate lfindices
    for (c = 0; c < 3; ++c) {
        // TODO spec bug: missing 2^16 scaling
        float mult_lf = f.m_lf_scaled[c] / cast(float) (f.global_scale * f.quant_lf) * cast(float) (65536 >> extra_prec);
        channel[c] = &m.channel[YXB2XYB[c]];
        j40__dequant_lf(channel[c], mult_lf, &lfquant[c]);
    }
    j40__add_thresholds(&lfindices, channel[0], f.lf_thr[0].ptr, f.nb_lf_thr[0]);
    j40__multiply_each_u8(&lfindices, f.nb_lf_thr[0] + 1);
    j40__add_thresholds(&lfindices, channel[2], f.lf_thr[2].ptr, f.nb_lf_thr[2]);
    j40__multiply_each_u8(&lfindices, f.nb_lf_thr[2] + 1);
    j40__add_thresholds(&lfindices, channel[1], f.lf_thr[1].ptr, f.nb_lf_thr[1]);

    // apply smoothing to LfQuant
    if (!f.skip_adapt_lf_smooth) do { if (J40_UNLIKELY(j40__smooth_lf(st, gg, lfquant[]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    memcpy(outlfquant.ptr, lfquant.ptr, j40__plane.sizeof * 3);
    gg.lfindices = lfindices;
    return 0;

J40__ON_ERROR:
    for (c = 0; c < 3; ++c) 
        j40__free_plane(&lfquant[c]);
    j40__free_plane(&lfindices);
    return st.err;
}

j40_err j40__hf_metadata(j40__st *st, int nb_varblocks,
                         j40__modular *m, 
                         const j40__plane[] lfquant, 
                         j40__lf_group_st *gg) 
{
    assert(lfquant.length == 3);
    j40__frame_st *f = st.frame;
    j40__plane blocks;
    j40__varblock *varblocks = null;
    float*[3 /*xyb*/] coeffs    = [null, null, null];
    float*[3 /*xyb*/] llfcoeffs = [null, null, null];
    size_t[3] coeffs_misalign   = [0, 0, 0];
    int log_gsize8 = f.group_size_shift - 3;
    int ggw8 = gg.width8, ggh8 = gg.height8;
    int voff, coeffoff;
    int x0, y0, x1, y1, i, j, c;

    gg.xfromy = m.channel[0];
    gg.bfromy = m.channel[1];
    gg.sharpness = m.channel[3];
    memset(&m.channel[0], 0, j40__plane.sizeof);
    memset(&m.channel[1], 0, j40__plane.sizeof);
    memset(&m.channel[3], 0, j40__plane.sizeof);

    do { if (J40_UNLIKELY(j40__init_plane(st, J40__PLANE_I32, ggw8, ggh8, J40__PLANE_CLEAR, &blocks))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    
    varblocks = cast(j40__varblock*) j40__malloc(cast(size_t) nb_varblocks, j40__varblock.sizeof);
    
    for (c = 0; c < 3; ++c) { // TODO account for chroma subsampling

        llfcoeffs[c] = cast(float*) j40__malloc(cast(size_t)(ggw8 * ggh8), float.sizeof);

        coeffs[c] = cast(float*) j40__alloc_aligned( (float.sizeof) * cast(size_t) (ggw8 * ggh8 * 64), J40__COEFFS_ALIGN, &coeffs_misalign[c]);

        for (i = 0; i < ggw8 * ggh8 * 64; ++i) coeffs[c][i] = 0.0f;
    }

    // temporarily use coeffoff_qfidx to store DctSelect
    if (m.channel[2].type == J40__PLANE_I16) {
        short *blockinfo0 = J40__I16_PIXELS(&m.channel[2], 0);
        short *blockinfo1 = J40__I16_PIXELS(&m.channel[2], 1);
        for (i = 0; i < nb_varblocks; ++i) {
            varblocks[i].coeffoff_qfidx = blockinfo0[i];
            varblocks[i].hfmul.m1 = blockinfo1[i];
        }
    } else {
        int *blockinfo0 = J40__I32_PIXELS(&m.channel[2], 0);
        int *blockinfo1 = J40__I32_PIXELS(&m.channel[2], 1);
        for (i = 0; i < nb_varblocks; ++i) {
            varblocks[i].coeffoff_qfidx = blockinfo0[i];
            varblocks[i].hfmul.m1 = blockinfo1[i];
        }
    }

    // place varblocks
    voff = coeffoff = 0;
    for (y0 = 0; y0 < ggh8; ++y0) for (x0 = 0; x0 < ggw8; ++x0) {
        int dctsel, log_vh, log_vw, vh8, vw8;
        const(j40__dct_select)* dct;
        if (J40__I32_PIXELS(&blocks, y0)[x0]) continue;

        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((voff < nb_varblocks) == 0)) { j40__set_error(st, J40__4("vblk")); goto J40__ON_ERROR; } } while (0); 
        dctsel = varblocks[voff].coeffoff_qfidx;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((0 <= dctsel && dctsel < J40__NUM_DCT_SELECT) == 0)) { j40__set_error(st, J40__4("dct?")); goto J40__ON_ERROR; } } while (0);
        dct = &J40__DCT_SELECT[dctsel];
        f.dct_select_used |= 1 << dctsel;
        f.order_used |= 1 << dct.order_idx;
        varblocks[voff].coeffoff_qfidx = coeffoff;
        assert(coeffoff % 64 == 0);

        log_vh = dct.log_rows;
        log_vw = dct.log_columns;
        assert(log_vh >= 3 && log_vw >= 3 && log_vh <= 8 && log_vw <= 8);
        vw8 = 1 << (log_vw - 3);
        vh8 = 1 << (log_vh - 3);
        x1 = x0 + vw8 - 1;
        y1 = y0 + vh8 - 1;
        // SPEC the first available block in raster order SHOULD be the top-left corner of
        // the next varblock, otherwise it's an error (no retry required)
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((x1 < ggw8 && (x0 >> log_gsize8) == (x1 >> log_gsize8)) == 0)) { j40__set_error(st, J40__4("vblk")); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((y1 < ggh8 && (y0 >> log_gsize8) == (y1 >> log_gsize8)) == 0)) { j40__set_error(st, J40__4("vblk")); goto J40__ON_ERROR; } } while (0);

        for (i = 0; i < vh8; ++i) {
            int *blockrow = J40__I32_PIXELS(&blocks, y0 + i);
            for (j = 0; j < vw8; ++j) blockrow[x0 + j] = 1 << 20 | voff;
        }
        J40__I32_PIXELS(&blocks, y0)[x0] = (dctsel + 2) << 20 | voff;

        
        if (log_vw <= 3 && log_vh <= 3) {
            for (c = 0; c < 3; ++c) llfcoeffs[c][coeffoff >> 6] = J40__F32_PIXELS(&lfquant[c], y0)[x0];
        } 
        else 
        {
            float[1024] scratch; // DCT256x256 requires 32x32
            for (c = 0; c < 3; ++c) 
            {
                float *llfcoeffs_c = llfcoeffs[c] + (coeffoff >> 6);
                for (i = 0; i < vh8; ++i) 
                {
                    const(float)* lfquantrow = J40__F32_PIXELS(&lfquant[c], y0 + i);
                    for (j = 0; j < vw8; ++j) llfcoeffs_c[i * vw8 + j] = lfquantrow[x0 + j];
                }
                // TODO spec bug: DctSelect type IDENTIFY [sic] no longer exists
                // TODO spec issue: DCT8x8 doesn't need this
                j40__forward_dct2d_scaled_for_llf(llfcoeffs_c, scratch.ptr, log_vh - 3, log_vw - 3);
            }
        }

        coeffoff += 1 << (log_vw + log_vh);
        ++voff;
    }
     // TODO spec issue: missing
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((voff == nb_varblocks) == 0)) { j40__set_error(st, J40__4("vblk")); goto J40__ON_ERROR; } } while (0); 
    // TODO both libjxl and spec don't check for coeffoff == ggw8 * ggh8, but they probably should?

    // compute qf_idx and hfmul.inv for later use
    assert(f.nb_qf_thr < 16);
    for (j = 0; j < f.nb_qf_thr; ++j) {
        for (i = 0; i < nb_varblocks; ++i) {
            varblocks[i].coeffoff_qfidx += varblocks[i].hfmul.m1 >= f.qf_thr[j];
        }
    }
    for (i = 0; i < nb_varblocks; ++i) 
    {
        varblocks[i].hfmul.inv = 1.0f / (cast(float) varblocks[i].hfmul.m1 + 1.0f);
    }

    gg.nb_varblocks = nb_varblocks;
    gg.blocks = blocks;
    gg.varblocks = varblocks;
    for (c = 0; c < 3; ++c) {
        gg.llfcoeffs[c] = llfcoeffs[c];
        gg.coeffs[c] = coeffs[c];
        gg.coeffs_misalign[c] = cast(ubyte) coeffs_misalign[c];
    }
    return 0;

J40__ON_ERROR:
    j40__free_plane(&blocks);
    j40__free(varblocks);
    for (c = 0; c < 3; ++c) {
        j40__free_aligned(coeffs[c], J40__COEFFS_ALIGN, coeffs_misalign[c]);
        j40__free(llfcoeffs[c]);
    }
    return st.err;
}

j40_err j40__lf_group(j40__st *st, j40__lf_group_st *gg) {
    j40__frame_st *f = st.frame;
    long ggidx = gg.idx;
    long sidx0 = 1 + ggidx, sidx1 = 1 + f.num_lf_groups + ggidx, sidx2 = 1 + 2 * f.num_lf_groups + ggidx;
    j40__plane[3] lfquant;
    j40__modular m;
    int i;

    // TODO factor into j40__init_modular_for_lf_group
    for (i = f.num_gm_channels; i < f.gmodular.num_channels; ++i) {
        j40__plane *c = &f.gmodular.channel[i];
        if (c.hshift >= 3 && c.vshift >= 3) 
        {
            do { j40__set_error(st, J40__4("TODO: ModularLfGroup decoding should continue here")); goto J40__ON_ERROR; } while (0);
        }
    }

    if (!f.is_modular) 
    {
        int ggw8 = gg.width8, ggh8 = gg.height8;
        int ggw64 = gg.width64, ggh64 = gg.height64;
        int[4] w, h;
        int nb_varblocks;

        assert(ggw8 <= 1024 && ggh8 <= 1024);

        // LfQuant
        if (!f.use_lf_frame) {
            int extra_prec = j40__u(st, 2), c;
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((f.jpeg_upsampling == 0) == 0)) { j40__set_error(st, J40__4("TODO: subimage w/h depends on jpeg_upsampling")); goto J40__ON_ERROR; } } while (0);
            w[0] = w[1] = w[2] = ggw8;
            h[0] = h[1] = h[2] = ggh8;
            do { if (J40_UNLIKELY(j40__init_modular(st, 3, w.ptr, h.ptr, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(j40__modular_header(st, f.global_tree, &f.global_codespec, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(j40__allocate_modular(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            for (c = 0; c < m.num_channels; ++c) do { if (J40_UNLIKELY(j40__modular_channel(st, &m, c, sidx0))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &m.code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(j40__inverse_transform(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            
            
            do { if (J40_UNLIKELY(j40__lf_quant(st, extra_prec, &m, gg, lfquant))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            j40__free_modular(&m);
        } else {
            do { j40__set_error(st, J40__4("TODO: persist lfquant and use it in later frames")); goto J40__ON_ERROR; } while (0);
        }

        
        
        nb_varblocks = j40__u(st, j40__ceil_lg32(cast(uint) (ggw8 * ggh8))) + 1; 
        w[0] = w[1] = ggw64; h[0] = h[1] = ggh64; 
        w[2] = nb_varblocks; h[2] = 2; 
        w[3] = ggw8; h[3] = ggh8; 
        do { if (J40_UNLIKELY(j40__init_modular(st, 4, w.ptr, h.ptr, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__modular_header(st, f.global_tree, &f.global_codespec, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__allocate_modular(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        for (i = 0; i < m.num_channels; ++i) do { if (J40_UNLIKELY(j40__modular_channel(st, &m, i, sidx2))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &m.code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__inverse_transform(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__hf_metadata(st, nb_varblocks, &m, lfquant, gg))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__free_modular(&m);
        for (i = 0; i < 3; ++i) j40__free_plane(&lfquant[i]);
    }

    return 0;

J40__ON_ERROR:
    j40__free_modular(&m);
    for (i = 0; i < 3; ++i) j40__free_plane(&lfquant[i]);
    if (gg) j40__free_lf_group(gg);
    return st.err;
}

void j40__free_lf_group(j40__lf_group_st *gg) {
    int i;
    for (i = 0; i < 3; ++i) {
        j40__free(gg.llfcoeffs[i]);
        j40__free_aligned(gg.coeffs[i], J40__COEFFS_ALIGN, gg.coeffs_misalign[i]);
        gg.llfcoeffs[i] = null;
        gg.coeffs[i] = null;
    }
    j40__free_plane(&gg.xfromy);
    j40__free_plane(&gg.bfromy);
    j40__free_plane(&gg.sharpness);
    j40__free_plane(&gg.blocks);
    j40__free_plane(&gg.lfindices);
    j40__free(gg.varblocks);
    gg.varblocks = null;
}

////////////////////////////////////////////////////////////////////////////////
// HfGlobal and HfPass

// reads both HfGlobal and HfPass (SPEC they form a single group)
j40_err j40__hf_global(j40__st *st) {
    j40__frame_st *f = st.frame;
    long sidx_base = 1 + 3 * f.num_lf_groups;
    j40__code_spec codespec;
    j40__code_st code;
    int i, j, c;

    assert(!f.is_modular);

    // dequantization matrices
    if (!j40__u(st, 1)) {
        // TODO spec improvement: encoding mode 1..5 are only valid for 0-3/9-10 since it requires 8x8 matrix, explicitly note this
        for (i = 0; i < J40__NUM_DCT_PARAMS; ++i) // SPEC not 11, should be 17
        { 
            j40__dct_params dct = J40__DCT_PARAMS[i];
            int rows = 1 << cast(int) dct.log_rows, 
                columns = 1 << cast(int) dct.log_columns;
            do { if (J40_UNLIKELY(j40__read_dq_matrix(st, rows, columns, sidx_base + i, f.global_tree, &f.global_codespec, &f.dq_matrix[i]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
    }

    // TODO is it possible that num_hf_presets > num_groups? otherwise j40__at_most is better
    f.num_hf_presets = j40__u(st, j40__ceil_lg32(cast(uint) f.num_groups)) + 1;
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; } while (0);

    // HfPass
    for (i = 0; i < f.num_passes; ++i) {
        int used_orders = j40__u32(st, 0x5f, 0, 0x13, 0, 0, 0, 0, 13);
        if (used_orders > 0) {
            do { if (J40_UNLIKELY(j40__read_code_spec(st, 8, &codespec))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            j40__init_code(&code, &codespec);
        }
        for (j = 0; j < J40__NUM_ORDERS; ++j) {
            if (used_orders >> j & 1) {
                int size = 1 << (J40__LOG_ORDER_SIZE[j][0] + J40__LOG_ORDER_SIZE[j][1]);
                for (c = 0; c < 3; ++c) { // SPEC this loop is omitted
                    do { if (J40_UNLIKELY(j40__permutation(st, &code, size, size / 64, &f.orders[i][j][c]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                }
            }
        }
        if (used_orders > 0) {
            do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            j40__free_code_spec(&codespec);
        }

        do { if (J40_UNLIKELY(j40__read_code_spec(st, 495 * f.nb_block_ctx * f.num_hf_presets, &f.coeff_codespec[i]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }

J40__ON_ERROR:
    j40__free_code(&code);
    j40__free_code_spec(&codespec);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// PassGroup

j40_err j40__hf_coeffs(
    j40__st *st, int ctxoff, int pass,
    int gx_in_gg, int gy_in_gg, int gw, int gh, j40__lf_group_st *gg)
{
    alias j40_i8x3 = byte[3];
    const(j40__frame_st)* f = st.frame;
    int gw8 = j40__ceil_div32(gw, 8), gh8 = j40__ceil_div32(gh, 8);
    byte[3] *nonzeros = null;
    j40__code_st code;
    int lfidx_size = (f.nb_lf_thr[0] + 1) * (f.nb_lf_thr[1] + 1) * (f.nb_lf_thr[2] + 1);
    int x8, y8, i, j, c_yxb;

    assert(gx_in_gg % 8 == 0 && gy_in_gg % 8 == 0);

    j40__init_code(&code, &f.coeff_codespec[pass]);

    // TODO spec bug: there are *three* NonZeros for each channel
    nonzeros = cast(j40_i8x3*) j40__malloc(cast(size_t) (gw8 * gh8), j40_i8x3.sizeof);
    
    for (y8 = 0; y8 < gh8; ++y8) for (x8 = 0; x8 < gw8; ++x8) {
        const(j40__dct_select)*dct;
        // TODO spec issue: missing x and y (here called x8 and y8)
        int ggx8 = x8 + gx_in_gg / 8, ggy8 = y8 + gy_in_gg / 8, nzpos = y8 * gw8 + x8;
        int voff = J40__I32_PIXELS(&gg.blocks, ggy8)[ggx8], dctsel = voff >> 20;
        int log_rows, log_columns, log_size;
        int coeffoff, qfidx, lfidx, bctx0, bctxc;

        if (dctsel < 2) continue; // not top-left block
        dctsel -= 2;
        voff &= 0xfffff;
        assert(dctsel < J40__NUM_DCT_SELECT);
        dct = &J40__DCT_SELECT[dctsel];
        log_rows = dct.log_rows;
        log_columns = dct.log_columns;
        log_size = log_rows + log_columns;

        coeffoff = gg.varblocks[voff].coeffoff_qfidx & ~15;
        qfidx = gg.varblocks[voff].coeffoff_qfidx & 15;
        // TODO spec improvement: explain why lf_idx is separately calculated
        // (answer: can be efficiently precomputed via vectorization)
        lfidx = J40__U8_PIXELS(&gg.lfindices, ggy8)[ggx8];
        bctx0 = (dct.order_idx * (f.nb_qf_thr + 1) + qfidx) * lfidx_size + lfidx;
        bctxc = 13 * (f.nb_qf_thr + 1) * lfidx_size;

        // unlike most places, this uses the YXB order
        for (c_yxb = 0; c_yxb < 3; ++c_yxb) 
        {
            static immutable int[3] YXB2XYB = [1, 0, 2];
            static immutable byte[64] TWICE_COEFF_FREQ_CTX = 
            [ // pre-multiplied by 2, [0] is unused
                -1,  0,  2,  4,  6,  8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28,
                30, 30, 32, 32, 34, 34, 36, 36, 38, 38, 40, 40, 42, 42, 44, 44,
                46, 46, 46, 46, 48, 48, 48, 48, 50, 50, 50, 50, 52, 52, 52, 52,
                54, 54, 54, 54, 56, 56, 56, 56, 58, 58, 58, 58, 60, 60, 60, 60,
            ];
            // TODO spec bug: CoeffNumNonzeroContext[9] should be 123, not 23
            static immutable short[64] TWICE_COEFF_NNZ_CTX =  // pre-multiplied by 2
            [
                  0,   0,  62, 124, 124, 186, 186, 186, 186, 246, 246, 246, 246, 304, 304, 304,
                304, 304, 304, 304, 304, 360, 360, 360, 360, 360, 360, 360, 360, 360, 360, 360,
                360, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412,
                412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412, 412,
            ];

            int c = YXB2XYB[c_yxb];
            float *coeffs = gg.coeffs[c] + coeffoff;
            const(int)* order = f.orders[pass][dct.order_idx][c];
            int bctx = f.block_ctx_map[bctx0 + bctxc * c_yxb]; // BlockContext()
            int nz, nzctx, cctx, qnz, prev;

            // orders should have been already converted from Lehmer code
            assert(order && ((f.order_loaded >> dct.order_idx) & 1));

            // predict and read the number of non-zero coefficients
            nz = x8 > 0 ?
                (y8 > 0 ? (nonzeros[nzpos - 1][c] + nonzeros[nzpos - gw8][c] + 1) >> 1 : nonzeros[nzpos - 1][c]) :
                (y8 > 0 ? nonzeros[nzpos - gw8][c] : 32);
            // TODO spec improvement: `predicted` can never exceed 63 in NonZerosContext(),
            // so better to make it a normative assertion instead of clamping
            // TODO spec question: then why the predicted value of 64 is reserved in the contexts?
            assert(nz < 64);
            nzctx = ctxoff + bctx + (nz < 8 ? nz : 4 + nz / 2) * f.nb_block_ctx;
            nz = j40__code(st, nzctx, 0, &code);
            // TODO spec issue: missing
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((nz <= (63 << (log_size - 6))) == 0)) { j40__set_error(st, J40__4("coef")); goto J40__ON_ERROR; } } while (0);

            qnz = j40__ceil_div32(nz, 1 << (log_size - 6)); // [0, 64)
            for (i = 0; i < (1 << (log_rows - 3)); ++i) {
                for (j = 0; j < (1 << (log_columns - 3)); ++j) {
                    nonzeros[nzpos + i * gw8 + j][c] = cast(byte) qnz;
                }
            }
            cctx = ctxoff + 458 * bctx + 37 * f.nb_block_ctx;

            prev = (nz <= (1 << (log_size - 4))); // TODO spec bug: swapped condition
            // TODO spec issue: missing size (probably W*H)
            for (i = 1 << (log_size - 6); nz > 0 && i < (1 << log_size); ++i) {
                int ctx = cctx +
                    TWICE_COEFF_NNZ_CTX[j40__ceil_div32(nz, 1 << (log_size - 6))] +
                    TWICE_COEFF_FREQ_CTX[i >> (log_size - 6)] + prev;
                // TODO spec question: can this overflow?
                // unlike modular there is no guarantee about "buffers" or anything similar here
                int ucoeff = j40__code(st, ctx, 0, &code);
                // TODO int-to-float conversion, is it okay?
                coeffs[order[i]] += cast(float) j40__unpack_signed(ucoeff);
                // TODO spec issue: normative indicator has changed from [[...]] to a long comment
                nz -= prev = (ucoeff != 0);
            }
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((nz == 0) == 0)) { j40__set_error(st, J40__4("coef")); goto J40__ON_ERROR; } } while (0); 
        }
    }

    do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    j40__free(nonzeros);
    return 0;

J40__ON_ERROR:
    j40__free_code(&code);
    j40__free(nonzeros);
    return st.err;
}

j40_err j40__pass_group(
    j40__st *st, int pass, int gx_in_gg, int gy_in_gg, int gw, int gh, long gidx,
    j40__lf_group_st *gg
) {
    j40__frame_st *f = st.frame;
    // SPEC "the number of tables" is fixed, no matter how many RAW quant tables are there
    long sidx = 1 + 3 * f.num_lf_groups + J40__NUM_DCT_PARAMS + pass * f.num_groups + gidx;
    j40__modular m;
    int i;

    if (!f.is_modular) {
        int ctxoff;
        // TODO spec issue: this offset is later referred so should be monospaced
        ctxoff = 495 * f.nb_block_ctx * j40__u(st, j40__ceil_lg32(cast(uint) f.num_hf_presets));
        do { if (J40_UNLIKELY(j40__hf_coeffs(st, ctxoff, pass, gx_in_gg, gy_in_gg, gw, gh, gg))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }

    do { if (J40_UNLIKELY(j40__init_modular_for_pass_group(st, f.num_gm_channels, gw, gh, 0, 3, &f.gmodular, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    if (m.num_channels > 0) {
        do { if (J40_UNLIKELY(j40__modular_header(st, f.global_tree, &f.global_codespec, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__allocate_modular(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        for (i = 0; i < m.num_channels; ++i) do { if (J40_UNLIKELY(j40__modular_channel(st, &m, i, sidx))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__finish_and_free_code(st, &m.code))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__inverse_transform(st, &m))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        j40__combine_modular_from_pass_group(f.num_gm_channels,
            gg.top + gy_in_gg, gg.left + gx_in_gg, 0, 3, &f.gmodular, &m);
        j40__free_modular(&m);
    }

    return 0;

J40__ON_ERROR:
    j40__free_modular(&m);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// coefficients to samples

void j40__dequant_hf(j40__st *st, j40__lf_group_st *gg) {
    // QM_SCALE[i] = 0.8^(i - 2)
    static immutable float[8] QM_SCALE = 
    [
        1.5625f, 1.25f, 1.0f, 0.8f, 0.64f, 0.512f, 0.4096f, 0.32768f
    ];

    j40__frame_st *f = st.frame;
    int ggw8 = gg.width8, ggh8 = gg.height8;
    float x_qm_scale, b_qm_scale, quant_bias_num = st.image.quant_bias_num;
    const(float)* quant_bias = st.image.quant_bias.ptr;
    int x8, y8, c, i;

    assert(f.x_qm_scale >= 0 && f.x_qm_scale < 8);
    assert(f.b_qm_scale >= 0 && f.b_qm_scale < 8);
    x_qm_scale = QM_SCALE[f.x_qm_scale];
    b_qm_scale = QM_SCALE[f.b_qm_scale];

    for (y8 = 0; y8 < ggh8; ++y8) for (x8 = 0; x8 < ggw8; ++x8) {
        const(j40__dct_select)*dct;
        const(j40__dq_matrix)*dqmat;
        int voff = J40__I32_PIXELS(&gg.blocks, y8)[x8], dctsel = voff >> 20, size;
        float[3 /*xyb*/] mult;

        if (dctsel < 2) continue; // not top-left block
        voff &= 0xfffff;
        dct = &J40__DCT_SELECT[dctsel - 2];
        size = 1 << (dct.log_rows + dct.log_columns);
        // TODO spec bug: spec says mult[1] = HfMul, should be 2^16 / (global_scale * HfMul)
        mult[1] = 65536.0f / cast(float) f.global_scale * gg.varblocks[voff].hfmul.inv;
        mult[0] = mult[1] * x_qm_scale;
        mult[2] = mult[1] * b_qm_scale;
        dqmat = &f.dq_matrix[dct.param_idx];
        assert(dqmat.mode == J40__DQ_ENC_RAW); // should have been already loaded

        for (c = 0; c < 3; ++c) {
            float *coeffs = gg.coeffs[c] + (gg.varblocks[voff].coeffoff_qfidx & ~15);
            for (i = 0; i < size; ++i) { // LLF positions are left unused and can be clobbered
                // TODO spec issue: "quant" is a variable name and should be monospaced
                if (-1.0f <= coeffs[i] && coeffs[i] <= 1.0f) {
                    coeffs[i] *= quant_bias[c]; // TODO coeffs[i] is integer at this point?
                } else {
                    coeffs[i] -= quant_bias_num / coeffs[i];
                }
                coeffs[i] *= mult[c] / dqmat.params[i][c]; // TODO precompute this
            }
        }
    }
}

j40_err j40__combine_vardct_from_lf_group(j40__st *st, const j40__lf_group_st *gg) 
{
    j40__image_st *im = st.image;
    j40__frame_st *f = st.frame;
    int ggw8 = gg.width8, ggh8 = gg.height8;
    int ggw = gg.width, ggh = gg.height;
    float kx_lf, kb_lf;
    float[3 /*xyb*/] cbrt_opsin_bias;
    float *scratch = null, scratch2;
    float*[3] samples = [null, null, null];
    int x8, y8, x, y, i, c;

    for (c = 0; c < 3; ++c) 
    {
        samples[c] = cast(float*) j40__malloc(cast(size_t)(ggw * ggh), float.sizeof);
    }
    // TODO allocates the same amount of memory regardless of transformations used

    scratch = cast(float*) j40__malloc(2 * 65536, float.sizeof);
    scratch2 = scratch + 65536;

    kx_lf = f.base_corr_x + cast(float) f.x_factor_lf * f.inv_colour_factor;
    kb_lf = f.base_corr_b + cast(float) f.b_factor_lf * f.inv_colour_factor;

    for (y8 = 0; y8 < ggh8; ++y8) for (x8 = 0; x8 < ggw8; ++x8) {
        const(j40__dct_select)*dct;
        int voff = J40__I32_PIXELS(&gg.blocks, y8)[x8], dctsel = voff >> 20;
        int size, effvw, effvh, vw8, vh8, samplepos;
        int coeffoff;
        const(float)*[3 /*xyb*/] coeffs;
        const(float)*[3 /*xyb*/] llfcoeffs;
        float kx_hf, kb_hf;

        if (dctsel < 2) continue; // not top-left block
        dctsel -= 2;
        voff &= 0xfffff;
        dct = &J40__DCT_SELECT[dctsel];
        size = 1 << (dct.log_rows + dct.log_columns);
        coeffoff = gg.varblocks[voff].coeffoff_qfidx & ~15;
        for (c = 0; c < 3; ++c) {
            coeffs[c] = gg.coeffs[c] + coeffoff;
            llfcoeffs[c] = gg.llfcoeffs[c] + (coeffoff >> 6);
        }

        // TODO spec bug: x_factor and b_factor (for HF) is constant in the same varblock,
        // even when the varblock spans multiple 64x64 rectangles
        kx_hf = f.base_corr_x + f.inv_colour_factor * (gg.xfromy.type == J40__PLANE_I16 ?
            cast(float) J40__I16_PIXELS(&gg.xfromy, y8 / 8)[x8 / 8] :
            cast(float) J40__I32_PIXELS(&gg.xfromy, y8 / 8)[x8 / 8]);
        kb_hf = f.base_corr_b + f.inv_colour_factor * (gg.bfromy.type == J40__PLANE_I16 ?
            cast(float) J40__I16_PIXELS(&gg.bfromy, y8 / 8)[x8 / 8] :
            cast(float) J40__I32_PIXELS(&gg.bfromy, y8 / 8)[x8 / 8]);

        effvh = j40__min32(ggh - y8 * 8, 1 << dct.log_rows);
        effvw = j40__min32(ggw - x8 * 8, 1 << dct.log_columns);
        samplepos = (y8 * 8) * ggw + (x8 * 8);
        // this is for LLF coefficients, which may have been transposed
        vh8 = 1 << (j40__min32(dct.log_rows, dct.log_columns) - 3);
        vw8 = 1 << (j40__max32(dct.log_rows, dct.log_columns) - 3);

        for (c = 0; c < 3; ++c) {
            // chroma from luma (CfL), overwrite LLF coefficients on the way
            // TODO skip CfL if there's subsampled channel
            switch (c) {
            case 0: // X
                for (i = 0; i < size; ++i) scratch[i] = coeffs[0][i] + coeffs[1][i] * kx_hf;
                for (y = 0; y < vh8; ++y) for (x = 0; x < vw8; ++x) {
                    scratch[y * vw8 * 8 + x] = llfcoeffs[0][y * vw8 + x] + llfcoeffs[1][y * vw8 + x] * kx_lf;
                }
                break;
            case 1: // Y
                for (i = 0; i < size; ++i) scratch[i] = coeffs[1][i];
                for (y = 0; y < vh8; ++y) for (x = 0; x < vw8; ++x) {
                    scratch[y * vw8 * 8 + x] = llfcoeffs[1][y * vw8 + x];
                }
                break;
            case 2: // B
                for (i = 0; i < size; ++i) scratch[i] = coeffs[2][i] + coeffs[1][i] * kb_hf;
                for (y = 0; y < vh8; ++y) for (x = 0; x < vw8; ++x) {
                    scratch[y * vw8 * 8 + x] = llfcoeffs[2][y * vw8 + x] + llfcoeffs[1][y * vw8 + x] * kb_lf;
                }
                break;
            default: J40__UNREACHABLE();
            }

            // inverse DCT
            switch (dctsel) {
            case 1: j40__inverse_hornuss(scratch); break; // Hornuss
            case 2: j40__inverse_dct11(scratch); break; // DCT11
            case 3: j40__inverse_dct22(scratch); break; // DCT22
            case 12: j40__inverse_dct23(scratch); break; // DCT23
            case 13: j40__inverse_dct32(scratch); break; // DCT32
            case 14: j40__inverse_afv(scratch, 0, 0); break; // AFV0
            case 15: j40__inverse_afv(scratch, 1, 0); break; // AFV1
            case 16: j40__inverse_afv(scratch, 0, 1); break; // AFV2
            case 17: j40__inverse_afv(scratch, 1, 1); break; // AFV3
            default: // every other DCTnm where n, m >= 3
                j40__inverse_dct2d(scratch, scratch2, dct.log_rows, dct.log_columns);
                break;
            }

            if (0) { // TODO display borders for the debugging
                for (x = 0; x < (1<<dct.log_columns); ++x) scratch[x] = 1.0f - cast(float) ((dctsel >> x) & 1);
                for (y = 0; y < (1<<dct.log_rows); ++y) scratch[y << dct.log_columns] = 1.0f - cast(float) ((dctsel >> y) & 1);
            }

            // reposition samples into the rectangular grid
            // TODO spec issue: overflown samples (due to non-8n dimensions) are probably ignored
            for (y = 0; y < effvh; ++y) for (x = 0; x < effvw; ++x) {
                samples[c][samplepos + y * ggw + x] = scratch[y << dct.log_columns | x];
            }
        }
    }

    // coeffs is now correctly positioned, copy to the modular buffer
    // TODO this is highly ad hoc, should be moved to rendering
    for (c = 0; c < 3; ++c) cbrt_opsin_bias[c] = cbrtf(im.opsin_bias[c]);
    for (y = 0; y < ggh; ++y) for (x = 0; x < ggw; ++x) {
        int pos = y * ggw + x;
        float[3] p = 
        [
            samples[1][pos] + samples[0][pos],
            samples[1][pos] - samples[0][pos],
            samples[2][pos],
        ];
        float itscale = 255.0f / im.intensity_target;
        for (c = 0; c < 3; ++c) {
            float pp = p[c] - cbrt_opsin_bias[c];
            samples[c][pos] = (pp * pp * pp + im.opsin_bias[c]) * itscale;
        }
    }
    for (c = 0; c < 3; ++c) {
        if (f.gmodular.channel[c].type == J40__PLANE_I16) {
            for (y = 0; y < ggh; ++y) {
                short *pixels = J40__I16_PIXELS(&f.gmodular.channel[c], gg.top + y);
                for (x = 0; x < ggw; ++x) {
                    int p = y * ggw + x;
                    float v = 
                        samples[0][p] * im.opsin_inv_mat[c][0] +
                        samples[1][p] * im.opsin_inv_mat[c][1] +
                        samples[2][p] * im.opsin_inv_mat[c][2];
                    // TODO very, very slow; probably different approximations per bpp ranges may be needed
                    v = (v <= 0.0031308f ? 12.92f * v : 1.055f * powf(v, 1.0f / 2.4f) - 0.055f); // to sRGB
                    // TODO overflow check
                    pixels[gg.left + x] = cast(short) (cast(float) ((1 << im.bpp) - 1) * v + 0.5f);
                }
            }
        } else {
            do { j40__set_error(st, J40__4("TODO: don't keep this here")); goto J40__ON_ERROR; } while (0);
        }
    }

J40__ON_ERROR:
    j40__free(scratch);
    for (c = 0; c < 3; ++c) j40__free(samples[c]);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// restoration filters

// TODO spec issue: restoration filters are applied to the entire image,
// even though their parameters are separately signaled via multiple groups or LF groups!



j40_err j40__gaborish(j40__st *st, j40__plane[] channels) 
{
    assert(channels.length == 3);
    j40__frame_st *f = st.frame;
    int width, height;
    int c, x, y;
    float* linebuf = null, nline, line;

    if (!f.gab.enabled) 
        return 0;
// #PORT
    assert(j40__plane_all_equal_sized(channels));
    assert(j40__plane_all_equal_typed(channels) == J40__PLANE_F32);
    width = channels[0].width;
    height = channels[0].height;

    linebuf = cast(float*) j40__malloc(cast(size_t)(width * 2), float.sizeof);
    
    for (c = 0; c < 3; ++c) 
    {
        float w0 = 1.0f, w1 = f.gab.weights[c][0], w2 = f.gab.weights[c][1];
        float wsum = w0 + w1 * 4 + w2 * 4;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__surely_nonzero(wsum)) == 0)) { j40__set_error(st, J40__4("gab0")); goto J40__ON_ERROR; } } while (0);
        w0 /= wsum; w1 /= wsum; w2 /= wsum;

        nline = linebuf + width; // intentionally uninitialized
        line = linebuf; // row -1 (= row 0 after mirroring)
        memcpy(line, J40__F32_PIXELS(&channels[c], 0), float.sizeof * cast(size_t) width);

        for (y = 0; y < height; ++y) 
        {
            float* sline, outline;
            float* temp = nline;
            nline = line;
            line = temp;
            sline = y + 1 < height ? J40__F32_PIXELS(&channels[c], y + 1) : line;
            outline = J40__F32_PIXELS(&channels[c], y);
            memcpy(line, outline, float.sizeof * cast(size_t) width);

            outline[0] =
                nline[0] * (w2 + w1) + nline[1] * w2 +
                 line[0] * (w1 + w0) +  line[1] * w1 +
                sline[0] * (w2 + w1) + sline[1] * w2;
            for (x = 1; x < width - 1; ++x) {
                outline[x] =
                    nline[x - 1] * w2 + nline[x] * w1 + nline[x + 1] * w2 +
                     line[x - 1] * w1 +  line[x] * w0 +  line[x + 1] * w1 +
                    sline[x - 1] * w2 + sline[x] * w1 + sline[x + 1] * w2;
            }
            if (width > 1) {
                outline[width - 1] =
                    nline[width - 2] * w2 + nline[width - 1] * (w1 + w2) +
                     line[width - 2] * w1 +  line[width - 1] * (w0 + w1) +
                    sline[width - 2] * w2 + sline[width - 1] * (w1 + w2);
            }
        }
    }

J40__ON_ERROR:
    j40__free(linebuf);
    return st.err;
}

int j40__mirror1d(int coord, int size) {
    while (1) {
        if (coord < 0) coord = -coord - 1;
        else if (coord >= size) coord = size * 2 - 1 - coord;
        else return coord;
    }
}

// computes out(x + 1, y + 1) = abs(in(x, y) - in(x + dx, y + dy)), up to mirroring.
// used to compute DistanceStep* functions; an increased border is required for correctness.
void j40__epf_distance(const(j40__plane)* in_, int dx, int dy, j40__plane *out_) {
    int width = in_.width, 
        height = in_.height;
    int x, y, xlo, xhi;

    assert(width + 2 == out_.width && height + 2 == out_.height);
    assert(in_.type == J40__PLANE_F32 && out_.type == J40__PLANE_F32);
    assert(-2 <= dx && dx <= 2 && -2 <= dy && dy <= 2);

    xlo = (dx > 0 ? 0 : -dx);
    xhi = (dx < 0 ? width : width - dx);

    // TODO spec issue: `[[(ix, iy) in coords]]` should be normative comments
    // TODO spec issue: `ix` and `iy` not defined in DistanceStep2, should be 0

    for (y = -1; y <= height; ++y) {
        int refy = j40__mirror1d(y, height), offy = j40__mirror1d(y + dy, height);
        const(float)*refpixels = J40__F32_PIXELS(in_, refy);
        const(float)*offpixels = J40__F32_PIXELS(in_, offy);
        float *outpixels = J40__F32_PIXELS(out_, y + 1) + 1;

        for (x = -1; x < xlo; ++x) {
            outpixels[x] = fabsf(refpixels[j40__mirror1d(x, width)] - offpixels[j40__mirror1d(x + dx, width)]);
        }
        for (; x < xhi; ++x) {
            outpixels[x] = fabsf(refpixels[x] - offpixels[x + dx]);
        }
        for (; x <= width; ++x) {
            outpixels[x] = fabsf(refpixels[j40__mirror1d(x, width)] - offpixels[j40__mirror1d(x + dx, width)]);
        }
    }
}

static immutable float J40__SIGMA_THRESHOLD = 0.3f;

// computes f(sigma) for each block, where f(x) = 1/x if x >= J40__SIGMA_THRESHOLD and < 0 otherwise.
// note that `inv_sigma` in the spec is not same to `1/sigma`, hence a different name.
j40_err j40__epf_recip_sigmas(j40__st *st, 
                              const(j40__lf_group_st)* gg, 
                              j40__plane *out_) {
    j40__frame_st *f = st.frame;
    int ggw8 = gg.width8, ggh8 = gg.height8;
    float[8] inv_quant_sharp_lut; // 1 / (epf_quant_mul * epf_sharp_lut[i])
    int x8, y8, i;

    do { if (J40_UNLIKELY(j40__init_plane(st, J40__PLANE_F32, gg.width8, gg.height8, J40__PLANE_FORCE_PAD, out_))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    for (i = 0; i < 8; ++i) {
        float quant_sharp_lut = f.epf.quant_mul * f.epf.sharp_lut[i];
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__surely_nonzero(quant_sharp_lut)) == 0)) { j40__set_error(st, J40__4("epf0")); goto J40__ON_ERROR; } } while (0);
        inv_quant_sharp_lut[i] = 1.0f / quant_sharp_lut;
    }

    if (gg.sharpness.type == J40__PLANE_I16) {
        ushort sharpness_ub = 0;
        for (y8 = 0; y8 < ggh8; ++y8) {
            const(short)*sharpness = J40__I16_PIXELS(&gg.sharpness, y8);
            float *recip_sigmas = J40__F32_PIXELS(out_, y8);
            for (x8 = 0; x8 < ggw8; ++x8) {
                sharpness_ub |= cast(ushort) sharpness[x8];
                recip_sigmas[x8] = inv_quant_sharp_lut[sharpness[x8] & 7];
            }
        }
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((sharpness_ub < 8) == 0)) { j40__set_error(st, J40__4("shrp")); goto J40__ON_ERROR; } } while (0);
    } else {
        uint sharpness_ub = 0;
        for (y8 = 0; y8 < ggh8; ++y8) {
            const(int)*sharpness = J40__I32_PIXELS(&gg.sharpness, y8);
            float *recip_sigmas = J40__F32_PIXELS(out_, y8);
            for (x8 = 0; x8 < ggw8; ++x8) {
                sharpness_ub |= cast(uint) sharpness[x8];
                recip_sigmas[x8] = inv_quant_sharp_lut[sharpness[x8] & 7];
            }
        }
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((sharpness_ub < 8) == 0)) { j40__set_error(st, J40__4("shrp")); goto J40__ON_ERROR; } } while (0);
    }

    for (y8 = 0; y8 < ggh8; ++y8) {
        const(int)*blocks = J40__I32_PIXELS(&gg.blocks, y8);
        float *recip_sigmas = J40__F32_PIXELS(out_, y8);
        for (x8 = 0; x8 < ggw8; ++x8) {
            int voff = blocks[x8] & 0xfffff;
            recip_sigmas[x8] *= gg.varblocks[voff].hfmul.inv;
            if (recip_sigmas[x8] > 1.0f / J40__SIGMA_THRESHOLD) recip_sigmas[x8] = -1.0f;
        }
    }

    return 0;

J40__ON_ERROR:
    j40__free_plane(out_);
    return st.err;
}

j40_err j40__epf_step(
    j40__st *st, 
    j40__plane[] channels,  // must be length 3
    float sigma_scale, 
    const(j40__plane)*recip_sigmas,
    int nkernels, 
    const int[2]* kernels, 
    j40__plane[3]* distances, 
    int dist_uses_cross,
    const(j40__lf_group_st)* gg) 
{
    assert(channels.length == 3);
    enum NKERNELS = 12; // except for the center

    j40__frame_st *f = st.frame;
    int ggw8 = gg.width8, ggh8 = gg.height8, width = gg.width, height = gg.height;
    int stride = width + 4, cstride = stride * 3;
    int[4] borderx = [-2, -1, width, width + 1];
    int[4] mirrorx;
    float* linebuf = null;
    float*[3][5] lines; // [y+2][c] for row y in the channel c, with mirrored borders

    float *recip_sigmas_for_modular = null; // only used for modular
    float border_sigma_scale;
    int x, y, c, k, i;

    assert(nkernels <= NKERNELS);

    assert(j40__plane_all_equal_sized(channels[0..3]));
    assert(j40__plane_all_equal_typed(channels[0..3]) == J40__PLANE_F32);
    assert(channels[0].width == width && channels[0].height == height);

    if (recip_sigmas) {
        assert(recip_sigmas.width == ggw8 && recip_sigmas.height == ggh8);
        assert(recip_sigmas.type == J40__PLANE_F32);
    } else {
        float recip_sigma;
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__surely_nonzero(f.epf.sigma_for_modular)) == 0)) { j40__set_error(st, J40__4("epf0")); goto J40__ON_ERROR; } } while (0);

        // sigma is fixed for modular, so if this is below the threshold no filtering happens
        if (f.epf.sigma_for_modular < J40__SIGMA_THRESHOLD) return 0;

        recip_sigmas_for_modular = cast(float*) j40__malloc(cast(size_t) ggw8, float.sizeof);
        
        recip_sigma = 1.0f / f.epf.sigma_for_modular;
        for (x = 0; x < ggw8; ++x) 
            recip_sigmas_for_modular[x] = recip_sigma;
    }

    sigma_scale *= 1.9330952441687859f; // -1.65 * 4 * (sqrt(0.5) - 1)
    border_sigma_scale = sigma_scale * f.epf.border_sad_mul;

    for (c = 0; c < 3; ++c) {
        for (k = 0; k < nkernels; ++k) {
            j40__epf_distance(&channels[c], kernels[k][0], kernels[k][1], &distances[k][c]);
        }
    }

    for (i = 0; i < 4; ++i) mirrorx[i] = j40__mirror1d(borderx[i], width);

    linebuf = cast(float*) j40__malloc(cast(size_t) (cstride * 4), float.sizeof);

    for (c = 0; c < 3; ++c) {
        int ym2 = j40__mirror1d(-2, height), ym1 = j40__mirror1d(-1, height);
        for (i = 0; i < 4; ++i) lines[i][c] = linebuf + cstride * c + stride * i + 1;
        memcpy(lines[1][c], J40__F32_PIXELS(&channels[c], ym2), float.sizeof * cast(size_t) width);
        memcpy(lines[2][c], J40__F32_PIXELS(&channels[c], ym1), float.sizeof * cast(size_t) width);
        memcpy(lines[3][c], J40__F32_PIXELS(&channels[c], 0), float.sizeof * cast(size_t) width);
        for (i = 0; i < 4; ++i) {
            int borderpos = c * cstride + borderx[i], mirrorpos = c * cstride + mirrorx[i];
            lines[1][c][borderpos] = lines[1][c][mirrorpos];
            lines[2][c][borderpos] = lines[2][c][mirrorpos];
            lines[3][c][borderpos] = lines[3][c][mirrorpos];
        }
    }

    for (y = 0; y < height; ++y) 
    {
        int y1 = j40__mirror1d(y + 1, height), y2 = j40__mirror1d(y + 2, height);
        float*[3] outline;
        const(float)*recip_sigma_row =
            recip_sigmas ? J40__F32_PIXELS(recip_sigmas, y / 8) : recip_sigmas_for_modular;

        float*[3][3][NKERNELS] distance_rows;// [kernel_idx][dy+1][c], all null-initialized

        for (c = 0; c < 3; ++c) {
            float *temp = lines[0][c];
            lines[0][c] = lines[1][c];
            lines[1][c] = lines[2][c];
            lines[2][c] = lines[3][c];
            lines[3][c] = temp;
            lines[4][c] = J40__F32_PIXELS(&channels[c], y2);
            outline[c] = J40__F32_PIXELS(&channels[c], y);

            memcpy(lines[3][c], J40__F32_PIXELS(&channels[c], y1), float.sizeof * cast(size_t) width);
            for (i = 0; i < 4; ++i) lines[3][c][borderx[i]] = lines[3][c][mirrorx[i]];

            for (k = 0; k < nkernels; ++k) {
                for (i = 0; i < 3; ++i) {
                    distance_rows[k][i][c] = J40__F32_PIXELS(&distances[k][c], y + i);
                }
            }
        }

        for (x = 0; x < width; ++x) {
            float recip_sigma = recip_sigma_row[x / 8], inv_sigma_times_pos_mult;
            float sum_weights;
            float[3] sum_channels;

            if (recip_sigma < 0.0f) {
                x += 7; // this and at most 7 subsequent pixels will be skipped anyway
                continue;
            }

            // TODO spec issue: "either coordinate" refers to both x and y (i.e. "borders")
            // according to the source code
            if ((((x + 1) | (y + 1)) & 7) < 2) {
                inv_sigma_times_pos_mult = recip_sigma * border_sigma_scale;
            } else {
                inv_sigma_times_pos_mult = recip_sigma * sigma_scale;
            }

            // kernels[*] do not include center, which distance is always 0
            sum_weights = 1.0f;
            for (c = 0; c < 3; ++c) sum_channels[c] = lines[2][c][x];

            if (dist_uses_cross) {
                for (k = 0; k < nkernels; ++k) {
                    float dist = 0.0f;
                    for (c = 0; c < 3; ++c) {
                        dist += f.epf.channel_scale[c] * (
                            distance_rows[k][1][c][x + 1] +
                            distance_rows[k][1][c][x + 0] + distance_rows[k][0][c][x + 1] +
                            distance_rows[k][2][c][x + 1] + distance_rows[k][1][c][x + 2]);
                    }
                    float weight = j40__maxf(0.0f, 1.0f + dist * inv_sigma_times_pos_mult);
                    sum_weights += weight;
                    for (c = 0; c < 3; ++c) {
                        sum_channels[c] += lines[2 + kernels[k][0]][c][x + kernels[k][1]] * weight;
                    }
                }
            } else {
                for (k = 0; k < nkernels; ++k) {
                    float dist = 0.0f;
                    for (c = 0; c < 3; ++c) {
                        dist += f.epf.channel_scale[c] * distance_rows[k][1][c][x + 1];
                    }
                    float weight = j40__maxf(0.0f, 1.0f + dist * inv_sigma_times_pos_mult);
                    sum_weights += weight;
                    for (c = 0; c < 3; ++c) {
                        sum_channels[c] += lines[2 + kernels[k][0]][c][x + kernels[k][1]] * weight;
                    }
                }
            }

            for (c = 0; c < 3; ++c) outline[c][x] = sum_channels[c] / sum_weights;
        }
    }

J40__ON_ERROR:
    j40__free(recip_sigmas_for_modular);
    j40__free(linebuf);
    return st.err;
}

j40_err j40__epf(j40__st *st, 
                 j40__plane[] channels, 
                 const(j40__lf_group_st)* gg) 
{
    assert(channels.length == 3);

    static immutable int[2][12] KERNELS12 = // 0 < L1 distance <= 2 (step 2)
    [
        [0,-2], [-1,-1], [-1,0], [-1,1], [0,-2], [0,-1], [0,1], [0,2], [-1,1], [-1,0], [-1,1], [0,2],
    ];
    
    static immutable int[2][4] KERNELS4 =  // 0 < L1 distance <= 1 (steps 0 and 1)
    [
        [0,-1], [-1,0], [1,0], [0,1],
    ];

    j40__frame_st *f = st.frame;
    j40__plane recip_sigmas_;
    j40__plane * recip_sigmas;
    j40__plane[3][12] distances; // #STACK suspicious?

    

    int k, c, maxnkernels = 0;

    if (f.epf.iters <= 0) return 0;

    if (!f.is_modular) {
        recip_sigmas = &recip_sigmas_;
        do { if (J40_UNLIKELY(j40__epf_recip_sigmas(st, gg, recip_sigmas))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    } else {
        recip_sigmas = null;
    }

    // TODO the current implementation takes up to 36 times the input image size of memory!
    maxnkernels = f.epf.iters >= 3 ? 12 : 4;
    for (k = 0; k < maxnkernels; ++k) for (c = 0; c < 3; ++c) {
        do { if (J40_UNLIKELY(j40__init_plane( st, J40__PLANE_F32, channels[c].width + 2, channels[c].height + 2, 0, &distances[k][c]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    }

    if (f.epf.iters >= 3) 
    { // step 0
        if (J40_UNLIKELY(j40__epf_step(st, channels, f.epf.pass0_sigma_scale, recip_sigmas, 12, KERNELS12.ptr, distances.ptr, 1, gg))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        }
    }
    if (f.epf.iters >= 1) 
    { // step 1
        if (J40_UNLIKELY(j40__epf_step(st, channels, 1.0f, recip_sigmas, 4, KERNELS4.ptr, distances.ptr, 1, gg))) 
        { 
            assert(st.err); 
            goto J40__ON_ERROR; 
        }
    }
    if (f.epf.iters >= 2) { // step 2
        do { if (J40_UNLIKELY(j40__epf_step( st, channels, f.epf.pass2_sigma_scale, recip_sigmas, 4, KERNELS4.ptr, distances.ptr, 0, gg))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    }

J40__ON_ERROR:
    if (recip_sigmas) j40__free_plane(recip_sigmas);
    for (k = 0; k < maxnkernels; ++k) for (c = 0; c < 3; ++c) j40__free_plane(&distances[k][c]);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// frame parsing primitives

struct j40__group_info // zero-initialized
{
    long ggidx = 0;
    int gx_in_gg = 0, 
        gy_in_gg = 0;
    int gw = 0, 
        gh = 0;
}

struct j40__section_st // zero-initialized
{
    j40__st *parent = null; // can be null if not initialized
    j40__st st;
    j40__buffer_st buffer;
}

j40_err j40__allocate_lf_groups(j40__st *st, j40__lf_group_st **out_) 
{
    j40__frame_st *f = st.frame;
    j40__lf_group_st *ggs = null;
    int ggsize = 8 << f.group_size_shift, gsize = 1 << f.group_size_shift;
    int ggx, ggy, ggidx = 0, gidx = 0, gstride = j40__ceil_div32(f.width, gsize);


    ggs = cast(j40__lf_group_st*) j40__calloc(cast(size_t) f.num_lf_groups, j40__lf_group_st.sizeof);

    for (ggy = 0; ggy < f.height; ggy += ggsize) {
        int ggh = j40__min32(ggsize, f.height - ggy);
        int grows = j40__ceil_div32(ggh, gsize);
        for (ggx = 0; ggx < f.width; ggx += ggsize, ++ggidx) {
            j40__lf_group_st *gg = &ggs[ggidx];
            int ggw = j40__min32(ggsize, f.width - ggx);
            int gcolumns = j40__ceil_div32(ggw, gsize);
            gg.idx = ggidx;
            gg.left = ggx; gg.top = ggy;
            gg.width = ggw; gg.height = ggh;
            gg.width8 = j40__ceil_div32(ggw, 8); gg.height8 = j40__ceil_div32(ggh, 8);
            gg.width64 = j40__ceil_div32(ggw, 64); gg.height64 = j40__ceil_div32(ggh, 64);
            gg.gidx = gidx + (ggx >> f.group_size_shift);
            gg.grows = grows;
            gg.gcolumns = gcolumns;
            gg.gstride = gstride;
        }
        gidx += grows * gstride;
    }

    assert(f.num_lf_groups == ggidx);
    assert(f.num_groups == gidx);
    *out_ = ggs;
J40__ON_ERROR:
    return st.err;
}

j40_err j40__prepare_dq_matrices(j40__st *st) {
    j40__frame_st *f = st.frame;
    int dct_select_not_loaded = f.dct_select_used & ~f.dct_select_loaded;
    int i;
    if (!dct_select_not_loaded) return 0;
    for (i = 0; i < J40__NUM_DCT_SELECT; ++i) {
        if (dct_select_not_loaded >> i & 1) {
            const j40__dct_select *dct = &J40__DCT_SELECT[i];
            int param_idx = dct.param_idx;
            do { if (J40_UNLIKELY(j40__load_dq_matrix(st, param_idx, &f.dq_matrix[param_idx]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
            f.dct_select_loaded |= 1 << i;
        }
    }
J40__ON_ERROR:
    return st.err;
}

j40_err j40__prepare_orders(j40__st *st) {
    j40__frame_st *f = st.frame;
    int order_not_loaded = f.order_used & ~f.order_loaded;
    int pass, i, c;
    if (!order_not_loaded) return 0;
    for (i = 0; i < J40__NUM_ORDERS; ++i) {
        if (order_not_loaded >> i & 1) {
            int log_rows = J40__LOG_ORDER_SIZE[i][0];
            int log_columns = J40__LOG_ORDER_SIZE[i][1];
            int *order;
            int temp, 
                skip = 1 << (log_rows + log_columns - 6);
            for (pass = 0; pass < f.num_passes; ++pass) for (c = 0; c < 3; ++c) {
                do { if (J40_UNLIKELY(j40__natural_order(st, log_rows, log_columns, &order))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
                j40__apply_permutation(order + skip, &temp, int.sizeof, f.orders[pass][i][c]);
                j40__free(f.orders[pass][i][c]);
                f.orders[pass][i][c] = order;
            }
            f.order_loaded |= 1 << i;
        }
    }
J40__ON_ERROR:
    return st.err;
}

j40__group_info j40__group_info_(j40__frame_st *f, long gidx) 
{
    j40__group_info info;
    int shift = f.group_size_shift;
    long row, column;
    assert(0 <= gidx && gidx < f.num_groups);
    row = gidx / f.gcolumns;
    column = gidx % f.gcolumns;
    info.ggidx = (row / 8) * f.ggcolumns + (column / 8);
    info.gx_in_gg = cast(int) (column % 8) << shift;
    info.gy_in_gg = cast(int) (row % 8) << shift;
    info.gw = cast(int) (j40__min64(f.width, (column + 1) << shift) - (column << shift));
    info.gh = cast(int) (j40__min64(f.height, (row + 1) << shift) - (row << shift));
    return info;
}

// creates a new per-section state `sst` which is identical to `*stptr` except for `buffer`,
// then ensures that only codestream offsets [codeoff, codeoff + size) are available to `sst`
// and updates `stptr` to point to `sst`, which should be restored with `j40__finish_section_state`.
j40_err j40__init_section_state(
    j40__st **stptr, j40__section_st *sst, long codeoff, int size
) {
    static immutable j40__buffer_st BUFFER_INIT;
    j40__st *st = *stptr;
    long fileoff, codeoff_limit;

    sst.parent = null;

    assert(codeoff <= INT64_MAX - size);
    do { if (J40_UNLIKELY(j40__map_codestream_offset(st, codeoff, &fileoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((j40__add64(codeoff, size, &codeoff_limit)) == 0)) { j40__set_error(st, J40__4("flen")); goto J40__ON_ERROR; } } while (0);

    do { if (J40_UNLIKELY(j40__seek_from_source(st, fileoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0); 

    sst.st = *st;
    sst.buffer = j40__buffer_st.init;
    sst.st.buffer = &sst.buffer;
    do { if (J40_UNLIKELY(j40__init_buffer(&sst.st, codeoff, codeoff_limit))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

J40__ON_ERROR:
    sst.parent = st;
    *stptr = &sst.st;
    return st.err;
}

j40_err j40__finish_section_state(j40__st **stptr, j40__section_st *sst, j40_err err) {
    j40__st *st;

    if (!sst.parent) return err;
    assert(*stptr == &sst.st);

    if (err) {
        *stptr = st = sst.parent;
        assert(sst.st.err == err);
        st.err = err;
        st.cannot_retry = sst.st.cannot_retry;
        // TODO `shrt` is not recoverable if this section is not the last section read
    } else {
        st = &sst.st;
        assert(!st.err);
        do { if (J40_UNLIKELY(j40__no_more_bytes(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }

J40__ON_ERROR:
    *stptr = st = sst.parent;
    j40__free_buffer(&sst.buffer);

    // ensure that other subsystems can't be accidentally deallocated
    sst.parent = null;
    sst.st.source = null;
    sst.st.container = null;
    sst.st.buffer = null;
    sst.st.image = null;
    sst.st.frame = null;

    return st.err;
}

j40_err j40__lf_global_in_section(j40__st *st, const j40__toc *toc) {
    j40__section_st sst;
    if (!toc.single_size) {
        do { if (J40_UNLIKELY(j40__init_section_state(&st, &sst, toc.lf_global_codeoff, toc.lf_global_size))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
    do { if (J40_UNLIKELY(j40__finish_section_state(&st, &sst, j40__lf_global(st)))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
J40__ON_ERROR:
    return st.err;
}

j40_err j40__hf_global_in_section(j40__st *st, const j40__toc *toc) 
{
    j40__section_st sst;
    if (st.frame.is_modular) {
        do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((toc.hf_global_size == 0) == 0)) { j40__set_error(st, J40__4("excs")); goto J40__ON_ERROR; } } while (0);
    } else {
        if (!toc.single_size) {
            do { if (J40_UNLIKELY(j40__init_section_state(&st, &sst, toc.hf_global_codeoff, toc.hf_global_size))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        }
        do { if (J40_UNLIKELY(j40__finish_section_state(&st, &sst, j40__hf_global(st)))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
J40__ON_ERROR:
    return st.err;
}

j40_err j40__lf_or_pass_group_in_section(j40__st *st, j40__toc *toc, j40__lf_group_st *ggs) {
    j40__section section = toc.sections[cast(int) toc.nsections_read];
    j40__section_st sst;

    if (section.pass < 0) { // LF group
        j40__lf_group_st *gg = &ggs[cast(int) section.idx];
        do { if (J40_UNLIKELY(j40__init_section_state(&st, &sst, section.codeoff, section.size))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__finish_section_state(&st, &sst, j40__lf_group(st, gg)))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        gg.loaded = 1;
        do { if (J40_UNLIKELY(j40__prepare_dq_matrices(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__prepare_orders(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    } 
    else 
    {
        // pass group
        j40__group_info info = j40__group_info_(st.frame, section.idx);
        j40__lf_group_st *gg = &ggs[cast(int) info.ggidx];
        assert(gg.loaded); // j40__read_toc should have taken care of this
        do { if (J40_UNLIKELY(j40__init_section_state(&st, &sst, section.codeoff, section.size))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
        do { if (J40_UNLIKELY(j40__finish_section_state(&st, &sst, j40__pass_group( st, section.pass, info.gx_in_gg, info.gy_in_gg, info.gw, info.gh, section.idx, gg)))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }

    ++toc.nsections_read;

J40__ON_ERROR:
    return st.err;
}

j40_err j40__combine_vardct(j40__st *st, j40__lf_group_st *ggs) {
    j40__frame_st *f = st.frame;
    long i;

    // GP: this used to leak one plane and f.gmodular.channel
    // See https://github.com/AuburnSounds/gamut/issues/69
    for (i = 0; i < f.gmodular.num_channels; ++i)
    {
        j40__free_plane(&f.gmodular.channel[cast(int) i]);
    }
    j40__free(f.gmodular.channel);
    f.gmodular.num_channels = 0;
    f.gmodular.channel = null;


    // TODO pretty incorrect to do this
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((!f.do_ycbcr && st.image.cspace != J40__CS_GREY) == 0)) { j40__set_error(st, J40__4("TODO: we don't yet do YCbCr or gray")); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((st.image.modular_16bit_buffers) == 0)) { j40__set_error(st, J40__4("TODO: !modular_16bit_buffers")); goto J40__ON_ERROR; } } while (0);
    f.gmodular.num_channels = 3;

    f.gmodular.channel = cast(j40__plane*) j40__calloc(3, j40__plane.sizeof);

    for (i = 0; i < f.gmodular.num_channels; ++i) {
        do { if (J40_UNLIKELY(j40__init_plane( st, J40__PLANE_I16, f.width, f.height, J40__PLANE_FORCE_PAD, &f.gmodular.channel[cast(int)i]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
    for (i = 0; i < f.num_lf_groups; ++i) {
        j40__dequant_hf(st, &ggs[cast(int)i]);
        do { if (J40_UNLIKELY(j40__combine_vardct_from_lf_group(st, &ggs[cast(int)i]))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }

J40__ON_ERROR:
    return st.err;
}

j40_err j40__end_of_frame(j40__st *st, const j40__toc *toc) {
    do { if (J40_UNLIKELY(j40__zero_pad_to_byte(st))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    if (toc.single_size) {
        long codeoff = j40__codestream_offset(st);
        if (codeoff < toc.end_codeoff) {
            st.cannot_retry = 1;
            do { j40__set_error(st, J40__4("shrt")); goto J40__ON_ERROR; } while (0);
        } else {
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((codeoff == toc.end_codeoff) == 0)) { j40__set_error(st, J40__4("excs")); goto J40__ON_ERROR; } } while (0);
        }
    } else {
        do { if (J40_UNLIKELY(j40__seek_buffer(st, toc.end_codeoff))) { assert(st.err); goto J40__ON_ERROR; } } while (0);
    }
J40__ON_ERROR:
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// rendering (currently very limited)

j40_err j40__render_to_u8x4_rgba(j40__st *st, j40__plane *out_) 
{
    j40__image_st *im = st.image;
    j40__frame_st *f = st.frame;
    j40__plane*[4] c; 
    j40__plane rgba;
    int maxpixel, maxpixel2;
    int i, x, y;

    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.modular_16bit_buffers) == 0)) { j40__set_error(st, J40__4("TODO: specialize for 32-bit")); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.bpp >= 8) == 0)) { j40__set_error(st, J40__4("TODO: does not yet support <8bpp")); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((im.exp_bits == 0) == 0)) { j40__set_error(st, J40__4("TODO: float samples not yet supported")); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((!(!f.do_ycbcr && im.xyb_encoded && im.cspace == J40__CS_GREY)) == 0)) { j40__set_error(st, J40__4("TODO: direct luma encoding not yet supported")); goto J40__ON_ERROR; } } while (0);


    assert(f.gmodular.num_channels >= 3);
    for (i = 0; i < 3; ++i) c[i] = &f.gmodular.channel[i];
    c[3] = null;
    for (i = 3; i < f.gmodular.num_channels; ++i) {
        j40__ec_info *ec = &im.ec_info[i - 3];
        if (ec.type == J40__EC_ALPHA) {
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((ec.bpp == im.bpp && ec.exp_bits == im.exp_bits) == 0)) { j40__set_error(st, J40__4("TODO: alpha channel has different bpp or sample type from color channels")); goto J40__ON_ERROR; } } while (0);

            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((ec.dim_shift == 0) == 0)) { j40__set_error(st, J40__4("TODO: subsampled alpha not yet supported")); goto J40__ON_ERROR; } } while (0);
            do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((!ec.data.alpha_associated) == 0)) { j40__set_error(st, J40__4("TODO: associated alpha not yet supported")); goto J40__ON_ERROR; } } while (0);
            c[3] = &f.gmodular.channel[i];
            break;
        }
    }

    do { if (J40_UNLIKELY(st.err)) goto J40__ON_ERROR; if (J40_UNLIKELY((f.width < INT32_MAX / 4) == 0)) { j40__set_error(st, J40__4("bigg")); goto J40__ON_ERROR; } } while (0);
    do { if (J40_UNLIKELY(j40__init_plane(st, J40__PLANE_U8, f.width * 4, f.height, J40__PLANE_FORCE_PAD, &rgba))) { assert(st.err); goto J40__ON_ERROR; } } while (0);

    maxpixel = (1 << im.bpp) - 1;
    maxpixel2 = (1 << (im.bpp - 1));
    for (y = 0; y < f.height; ++y) 
    {
        short*[4] pixels;
        ubyte *outpixels = J40__U8_PIXELS(&rgba, y);
        for (i = 0; i < 4; ++i) 
        {
            pixels[i] = c[i] ? J40__I16_PIXELS(c[i], y) : null;
        }

        for (x = 0; x < f.width; ++x) 
        {
            for (i = 0; i < 4; ++i) 
            {
                // TODO optimize
                int p = j40__min32(j40__max32(0, pixels[i] ? pixels[i][x] : maxpixel), maxpixel);
                outpixels[x * 4 + i] = cast(ubyte) ((p * 255 + maxpixel2) / maxpixel);
            }
        }
    }

    *out_ = rgba;
    return 0;

J40__ON_ERROR:
    j40__free_plane(&rgba);
    return st.err;
}

////////////////////////////////////////////////////////////////////////////////
// API utilities

// we don't trust callers and do the basic check ourselves
enum uint J40__IMAGE_MAGIC     = cast(uint) 0x7867ae21; // crc32("j40_image")
enum uint J40__IMAGE_ERR_MAGIC = cast(uint) 0xb26a48aa; // crc32("j40_image with error")
enum uint J40__IMAGE_OPEN_ERR_MAGIC = cast(uint) 0x02c2eb6d; // crc32("j40_image with open error")
enum uint J40__FRAME_MAGIC = cast(uint) 0x08a296b3; // crc32("j40_frame")
enum uint J40__FRAME_ERR_MAGIC = cast(uint) 0x16351564; // crc32("j40_frame with error")
enum uint J40__INNER_MAGIC = cast(uint) 0x5009e1c4; // crc32("j40__inner")*/

alias j40__origin = int;
enum : j40__origin 
{
    J40__ORIGIN_NONE = 0,

    // for j40_free; the next call will be the actual origin
    J40__ORIGIN_NEXT, 

    J40__ORIGIN_from_file, 

    // the last origin that can use alternative magic numbers, see J40__ORIGIN_LAST_ALT_MAGIC
    J40__ORIGIN_from_memory,  

    J40__ORIGIN_output_format, 
    J40__ORIGIN_next_frame, 
    J40__ORIGIN_current_frame, 
    J40__ORIGIN_frame_pixels, 
    J40__ORIGIN_error_string, 
    J40__ORIGIN_free,

    J40__ORIGIN_MAX,
    J40__ORIGIN_LAST_ALT_MAGIC = J40__ORIGIN_from_memory,
}

static immutable string[J40__ORIGIN_MAX] J40__ORIGIN_NAMES= 
[
    "(unknown)",
    null,
    "from_file", 
    "from_memory", 
    "output_format", 
    "next_frame", 
    "current_frame", 
    "frame_pixels_*", 
    "error_string", 
    "free",
];

struct error_string_t
{
    char[5] err; 
    string msg;
    string suffix;
}

static immutable error_string_t[] J40__ERROR_STRINGS = 
[
    error_string_t("Upt0", "`path` parameter is null", null ),
    error_string_t("Ubf0", "`buf` parameter is null", null ),
    error_string_t("Uch?", "Bad `channel` parameter", null ),
    error_string_t("Ufm?", "Bad `format` parameter", null ),
    error_string_t("Uof?", "Bad `channel` and `format` combination", null ),
    error_string_t("Urnd", "Frame is not yet rendered", null ),
    error_string_t("Ufre", "Trying to reuse already freed image", null ),
    error_string_t("!mem", "Out of memory", null ),
    error_string_t("!jxl", "The JPEG XL signature is not found", null ),
    error_string_t("open", "Failed to open file", null ),
    error_string_t("bigg", "Image dimensions are too large to handle", null ),
    error_string_t("flen", "File is too lengthy to handle", null ),
    error_string_t("shrt", "Premature end of file", null ),
    error_string_t("slim", "Image size limit reached", null ),
    error_string_t("elim", "Extra channel number limit reached", null ),
    error_string_t("xlim", "Modular transform limit reached", null ),
    error_string_t("tlim", "Meta-adaptive tree size or depth limit reached", null ),
    error_string_t("plim", "ICC profile length limit reached", null ),
    error_string_t("fbpp", "Given bits per pixel value is disallowed", null ), // "f" stands for "forbidden"
    error_string_t("fblk", "Black extra channel is disallowed", null ),
    error_string_t("fm32", "32-bit buffers for modular encoding are disallowed", null ),
    error_string_t("TODO", "Unimplemented feature encountered", null ), // TODO remove this when ready
    error_string_t("TEST", "Testing-only error occurred", null ),
];

enum J40__ERRBUF_LEN = 256;

// an API-level twin of `j40__st`; see `j40__st` documentation for the rationale for split.
struct j40__inner 
{
    uint magic; // should be J40__INNER_MAGIC

    //j40__mutex mutex;

    j40__origin origin; // error origin
    // same to those in j40__st
    j40_err err;
    int saved_errno;
    int cannot_retry;

    char[J40__ERRBUF_LEN] errbuf;

    int state; // used in j40_advance

    // subsystem contexts; copied to and from j40__st whenever needed
    j40__bits_st bits;
    j40__source_st source;
    j40__container_st container;
    j40__buffer_st buffer;
    j40__image_st image;
    j40__frame_st frame;
    j40__lf_group_st *lf_groups; // [frame.num_lf_groups]

    j40__toc toc;

    int rendered;
    j40__plane rendered_rgba;
}


j40_err j40__set_alt_magic(
    j40_err err, int saved_errno, j40__origin origin, j40_image *image
) {
    if (err == J40__4("open")) {
        image.magic = J40__IMAGE_OPEN_ERR_MAGIC ^ cast(uint) origin;
        image.u.saved_errno = saved_errno;
        return err;
    } else {
        image.magic = J40__IMAGE_ERR_MAGIC ^ cast(uint) origin;
        return image.u.err = err;
    }
}

j40_err j40__set_magic(j40__inner *inner, j40_image *image) {
    image.magic = J40__IMAGE_MAGIC;
    image.u.inner = inner;
    inner.magic = J40__INNER_MAGIC;
    return 0;
}

j40_err j40__check_image(j40_image *image, j40__origin neworigin, j40__inner **outinner) {
    *outinner = null;
    if (!image) return J40__4("Uim0");
    if (image.magic != J40__IMAGE_MAGIC) {
        uint origin = image.magic ^ J40__IMAGE_ERR_MAGIC;
        if (0 < origin && origin <= J40__ORIGIN_LAST_ALT_MAGIC) {
            if (origin == J40__ORIGIN_NEXT && neworigin) image.magic = J40__IMAGE_ERR_MAGIC ^ neworigin;
            return image.u.err;
        }
        origin = image.magic ^ J40__IMAGE_OPEN_ERR_MAGIC;
        if (0 < origin && origin <= J40__ORIGIN_LAST_ALT_MAGIC) return J40__4("open");
        return J40__4("Uim?");
    }
    if (!image.u.inner || image.u.inner.magic != J40__INNER_MAGIC) return J40__4("Uim?");
    *outinner = image.u.inner;
    return image.u.inner.err; // TODO handle cannot_retry in a better way
}

void j40__init_state(j40__st *st, j40__inner *inner) {
    st.err = 0;
    st.cannot_retry = 0;
    st.bits = inner.buffer.checkpoint;
    st.source = &inner.source;
    st.container = &inner.container;
    st.buffer = &inner.buffer;
    st.image = &inner.image;
    st.frame = &inner.frame;
    st.limits = &J40__MAIN_LV5_LIMITS;
}

void j40__save_state(j40__st *st, j40__inner *inner, j40__origin origin) {
    if (st.err) {
        inner.origin = origin;
        inner.err = st.err;
        inner.cannot_retry = st.cannot_retry;
    } else {
        inner.buffer.checkpoint = st.bits;
    }
}

// TODO expose this with a proper interface
j40_err j40__advance(j40__inner *inner, j40__origin origin) 
{
    j40__st stbuf = void;
    j40__st *st = &stbuf;
    j40__frame_st *f;
    j40_err err;
    j40__init_state(st, inner);

    f = st.frame;
    switch (inner.state) 
    {
        case 0: 

            { err = (j40__init_buffer(st, 0, INT64_MAX)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 31; case 31: }
            { err = (j40__signature(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 32; case 32: }
            { err = (j40__image_metadata(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 33; case 33: }

            if (st.image.want_icc) {
                { err = (j40__icc(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 36; case 36: }
            }

            // TODO should really be a loop, should we support multiple frames

            { 
                { err = (j40__frame_header(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 40; case 40: }
                if (!f.is_last) { err = (j40__set_error(st, J40__4("TODO: multiple frames"))); j40__save_state(st, inner, origin); if (err) return err; inner.state = 41; case 41: }
                if (f.type != J40__FRAME_REGULAR) { err = (j40__set_error(st, J40__4("TODO: non-regular frame"))); j40__save_state(st, inner, origin); if (err) return err; inner.state = 42; case 42: }
                { err = (j40__read_toc(st, &inner.toc)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 43; case 43: }

                { err = (j40__lf_global_in_section(st, &inner.toc)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 45; case 45: }
                { err = (j40__hf_global_in_section(st, &inner.toc)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 46; case 46: }

                { err = (j40__allocate_lf_groups(st, &inner.lf_groups)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 48; case 48: }

                if (inner.toc.single_size) {
                    assert(f.num_lf_groups == 1 && f.num_groups == 1 && f.num_passes == 1);
                    { err = (j40__lf_group(st, &inner.lf_groups[0])); j40__save_state(st, inner, origin); if (err) return err; inner.state = 52; case 52: }
                    { err = (j40__prepare_dq_matrices(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 53; case 53: }
                    { err = (j40__prepare_orders(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 54; case 54: }
                    { err = (j40__pass_group(st, 0, 0, 0, f.width, f.height, 0, &inner.lf_groups[0])); j40__save_state(st, inner, origin); if (err) return err; inner.state = 55; case 55: }
                    { err = (j40__zero_pad_to_byte(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 56; case 56: }
                } else {
                    while (inner.toc.nsections_read < inner.toc.nsections) {
                        { err = (j40__lf_or_pass_group_in_section(st, &inner.toc, inner.lf_groups)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 59; case 59: }
                    }
                }

                { err = (j40__end_of_frame(st, &inner.toc)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 63; case 63: }

                { err = (j40__inverse_transform(st, &f.gmodular)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 65; case 65: }
                if (!f.is_modular) { err = (j40__combine_vardct(st, inner.lf_groups)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 66; case 66: }
            }

            { err = (j40__no_more_bytes(st)); j40__save_state(st, inner, origin); if (err) return err; inner.state = 69; case 69: }
            break;

        default: J40__UNREACHABLE();
    }

    return 0;
}


void j40__free_inner(j40__inner *inner) 
{
    long i, num_lf_groups = inner.frame.num_lf_groups;
    j40__free_source(&inner.source);
    j40__free_container(&inner.container);
    j40__free_buffer(&inner.buffer);
    j40__free_image_state(&inner.image);
    j40__free_frame_state(&inner.frame);
    if (inner.lf_groups) {
        for (i = 0; i < num_lf_groups; ++i) j40__free_lf_group(&inner.lf_groups[cast(int)i]);
        free(inner.lf_groups);
    }
    j40__free_toc(&inner.toc);
    j40__free_plane(&inner.rendered_rgba);
    j40__free(inner);
}

////////////////////////////////////////////////////////////////////////////////
// public API (implementation)

public j40_err j40_error(const(j40_image)* image) 
{
    j40__inner *inner; // ignored
    // do not alter image.magic even for Ufre
    // const_cast here
    return j40__check_image(cast(j40_image *) image, J40__ORIGIN_NONE, &inner);
}

public const(char)* j40_error_string(j40_image* image) 
{
    // This is a TLS variable #TLS
    static char[J40__ERRBUF_LEN] static_errbuf;
    uint origin = J40__ORIGIN_NONE;
    j40_err err = 0;
    const(char)* msg, suffix;
    char *buf = null;
    int saved_errno = 0;
    int i, corrupted_image = 0;

    if (!image) 
    {
        snprintf(static_errbuf.ptr, J40__ERRBUF_LEN, "`image` parameter is null during j40_error_string".ptr);
        return static_errbuf.ptr;
    }
    if (image.magic == J40__IMAGE_MAGIC) 
    {
        if (image.u.inner && image.u.inner.magic == J40__INNER_MAGIC) 
        {
            origin = image.u.inner.origin;
            err = image.u.inner.err;
            buf = image.u.inner.errbuf.ptr;
            saved_errno = image.u.inner.saved_errno;
        } else {
            corrupted_image = 1;
        }
    } else {
        origin = image.magic ^ J40__IMAGE_ERR_MAGIC;
        if (0 < origin && origin <= J40__ORIGIN_LAST_ALT_MAGIC) {
            err = image.u.err;
            buf = static_errbuf.ptr;
            saved_errno = 0;
            // do not alter image.magic even for Ufre, but the message will be altered accordingly
            if (origin == J40__ORIGIN_NEXT) origin = J40__ORIGIN_error_string;
        } else {
            origin = image.magic ^ J40__IMAGE_OPEN_ERR_MAGIC;
            if (0 < origin && origin <= J40__ORIGIN_LAST_ALT_MAGIC) {
                err = J40__4("open");
                buf = static_errbuf.ptr;
                saved_errno = image.u.saved_errno;
            } else {
                corrupted_image = 1;
            }
        }
    }
    if (corrupted_image) {
        snprintf(static_errbuf.ptr, J40__ERRBUF_LEN,
            "`image` parameter is found corrupted during j40_error_string".ptr);
        return static_errbuf.ptr;
    }

    // TODO acquire a spinlock for buf if threaded

    msg = null;
    suffix = "";
    for (i = 0; i < J40__ERROR_STRINGS.length; ++i) 
    {
        if (err == J40__4(J40__ERROR_STRINGS[i].err)) 
        {
            msg = J40__ERROR_STRINGS[i].msg.ptr;
            if (J40__ERROR_STRINGS[i].suffix) 
                suffix = J40__ERROR_STRINGS[i].suffix.ptr;
            break;
        }
    }
    if (!msg) {
        snprintf(buf, J40__ERRBUF_LEN, "Decoding failed (%c%c%c%c) during j40_%s".ptr,
            err >> 24 & 0xff, err >> 16 & 0xff, err >> 8 & 0xff, err & 0xff, J40__ORIGIN_NAMES[origin].ptr);
    } else {
        snprintf(buf, J40__ERRBUF_LEN, "%s during j40_%s%s".ptr, msg, J40__ORIGIN_NAMES[origin].ptr, suffix);
    }
    return buf;
}

public j40_err j40_from_memory(j40_image *image, 
                        void *buf, 
                        size_t size, 
                        j40_memory_free_func freefunc) 
{
    static const j40__origin ORIGIN = J40__ORIGIN_from_memory;
    j40__inner *inner;
    j40__st stbuf = void;
    j40__st * st = &stbuf;

    if (!image) return J40__4("Uim0");
    if (!buf) return j40__set_alt_magic(J40__4("Ubf0"), 0, ORIGIN, image);

    inner = cast(j40__inner*) j40__calloc(1, j40__inner.sizeof);
    if (!inner) return j40__set_alt_magic(J40__4("!mem"), 0, ORIGIN, image);

    j40__init_state(st, inner);
    if (j40__init_memory_source(st, cast(ubyte*) buf, size, freefunc, &inner.source)) 
    {
        j40__free_inner(inner);
        return j40__set_alt_magic(st.err, 0, ORIGIN, image);
    } else {
        assert(!st.err);
        return j40__set_magic(inner, image);
    }
}


public j40_err j40_output_format(j40_image *image, int channel, int format) 
{
    static const j40__origin ORIGIN = J40__ORIGIN_output_format;
    j40__inner *inner;

    j40_err err = j40__check_image(cast(j40_image*) image, ORIGIN, &inner);
    if (err) return err;

    // TODO implement multiple output formats
    if (channel != J40_RGBA) 
    {
        inner.origin = ORIGIN;
        inner.err = J40__4("Uch?");
        return inner.err;
    }
    if (format != J40_U8X4)
    {
        inner.origin = ORIGIN;
        inner.err = J40__4("Ufm?");
        return inner.err;
    }
    if (!(channel == J40_RGBA && format == J40_U8X4))
    {
        inner.origin = ORIGIN;
        inner.err = J40__4("Uof?");
        return inner.err;
    }
    return 0;
}

public int j40_next_frame(j40_image *image) 
{
    static const j40__origin ORIGIN = J40__ORIGIN_next_frame;
    j40__inner *inner;
    j40__st stbuf = void;
    j40_err err;

    err = j40__check_image(image, ORIGIN, &inner);
    if (err) return 0; // does NOT return err!

    err = j40__advance(inner, ORIGIN);
    if (err) return 0;

    // we don't yet have multiple frames, so the second j40_next_frame call always returns 0
    if (inner.rendered) return 0;

    j40__init_state(&stbuf, inner);
    err = j40__render_to_u8x4_rgba(&stbuf, &inner.rendered_rgba);
    if (err) {
        inner.origin = ORIGIN;
        inner.err = err;
        return 0;
    }
    inner.rendered = 1;
    return 1;
}

public j40_frame j40_current_frame(j40_image *image) 
{
    static const j40__origin ORIGIN = J40__ORIGIN_current_frame;
    j40__inner *inner;
    j40_frame frame;
    j40_err err;

    err = j40__check_image(image, ORIGIN, &inner);
    frame.magic = J40__FRAME_ERR_MAGIC;
    frame.reserved = 0;
    frame.inner = inner;
    if (err) return frame;

    if (!inner.rendered) {
        if (!j40_next_frame(image)) { // if j40_next_frame hasn't been called, implicity call it
            if (inner.err) return frame; // at this point we are sure that inner exists
        }
    }

    frame.magic = J40__FRAME_MAGIC;
    return frame;
}

// Not: unlike original j40.h, this return a j40_pixels_u8x4 with null pointer in case of error
// With that, we now the allocation method of inner.rendered_rgba
public j40_pixels_u8x4 j40_frame_pixels_u8x4(j40_frame*frame, int channel) 
{
    static const j40__origin ORIGIN = J40__ORIGIN_frame_pixels;

    j40__inner*inner;
    j40_pixels_u8x4 pixels;

    if (!frame || frame.magic != J40__FRAME_MAGIC) 
        return j40_pixels_u8x4.init;
    inner = frame.inner;
    if (!inner || inner.magic != J40__INNER_MAGIC) 
        return j40_pixels_u8x4.init;

    // TODO support more channels
    if (channel != J40_RGBA) 
    {
        return j40_pixels_u8x4.init;
    }

    // TODO this condition is impossible under the current API
    if (!inner.rendered)
    {
        inner.origin = ORIGIN;
        inner.err = J40__4("Urnd");
        return j40_pixels_u8x4.init;
    }

    assert(inner.rendered_rgba.width % 4 == 0);
    pixels.width = inner.rendered_rgba.width / 4;
    pixels.height = inner.rendered_rgba.height;
    pixels.stride_bytes = inner.rendered_rgba.stride_bytes;
    pixels.data = cast(void*) inner.rendered_rgba.pixels;
    return pixels;

error:
    return j40_pixels_u8x4.init;
}

public const(j40_u8x4)* j40_row_u8x4(j40_pixels_u8x4 pixels, int y) 
{
    assert(0 <= y && y < pixels.height);
    assert(pixels.stride_bytes > 0);
    assert(pixels.data);
    return cast(const j40_u8x4*) (cast(const char*) pixels.data + cast(size_t) pixels.stride_bytes * cast(size_t) y);
}

public void j40_free(j40_image *image) 
{
    j40__inner *inner;
    j40__check_image(image, J40__ORIGIN_free, &inner);
    if (inner) j40__free_inner(inner);
    image.magic = J40__IMAGE_ERR_MAGIC ^ J40__ORIGIN_NEXT;
    image.u.err = J40__4("Ufre");
}
