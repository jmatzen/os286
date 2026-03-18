#include <stddef.h>

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;

#ifndef __WATCOMC__
#define __cdecl
#endif

#define ABI_ASSERT(name, expr) typedef char abi_assert_##name[(expr) ? 1 : -1]

struct pair16 {
    u16 lo;
    u16 hi;
};

struct mixed_layout {
    u8 tag;
    u16 value;
    u8 tail;
};

#ifdef __WATCOMC__
ABI_ASSERT(char_is_8_bits, sizeof(char) == 1);
ABI_ASSERT(short_is_16_bits, sizeof(short) == 2);
ABI_ASSERT(int_is_16_bits, sizeof(int) == 2);
ABI_ASSERT(long_is_32_bits, sizeof(long) == 4);
ABI_ASSERT(ptr_is_16_bits, sizeof(void *) == 2);
ABI_ASSERT(fn_ptr_is_16_bits, sizeof(int (__cdecl *)(void)) == 2);
ABI_ASSERT(pair16_size_is_4, sizeof(struct pair16) == 4);
ABI_ASSERT(pair16_hi_offset_is_2, offsetof(struct pair16, hi) == 2);
ABI_ASSERT(mixed_value_offset_is_2, offsetof(struct mixed_layout, value) == 2);
ABI_ASSERT(mixed_tail_offset_is_4, offsetof(struct mixed_layout, tail) == 4);
ABI_ASSERT(mixed_size_is_6, sizeof(struct mixed_layout) == 6);
#endif

u16 __cdecl abi_sum3(u16 first, u16 second, u16 third)
{
    return first + second + third;
}

u32 __cdecl abi_muladd32(u16 scale, u32 base)
{
    return base + ((u32)scale << 4);
}

struct pair16 __cdecl abi_pair_add(struct pair16 left, struct pair16 right)
{
    struct pair16 out;

    out.lo = left.lo + right.lo;
    out.hi = left.hi + right.hi;
    return out;
}

int __cdecl abi_caller(void)
{
    struct pair16 left;
    struct pair16 right;
    struct pair16 out;

    left.lo = 1;
    left.hi = 2;
    right.lo = 3;
    right.hi = 4;

    out = abi_pair_add(left, right);

    return abi_sum3(5, 6, 7)
        + (int)abi_muladd32(8, 0x1234UL)
        + out.lo
        + out.hi;
}
