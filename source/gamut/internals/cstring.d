/**
D string to C string.

Copyright: Copyright Guillaume Piolat 2022-2026
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.internals.cstring;

import core.stdc.stdlib: malloc, free;

//
// C string conversions
//
alias CString = CStringImpl!char;
alias CString16 = CStringImpl!wchar;

/// Zero-terminated C string, to replace toStringz and toUTF16z
struct CStringImpl(CharType) if (is(CharType: char) || is(CharType: wchar))
{
public:
nothrow:
@nogc:

    const(CharType)* storage() return
    {
        return _storage;
    }

    this(const(CharType)[] s)
    {
        // Always copy. We can't assume anything about the input.
        size_t len = s.length;
        CharType* buffer = cast(CharType*) malloc((len + 1) * CharType.sizeof);
        buffer[0..len] = s[0..len];
        buffer[len] = '\0';
        _storage = buffer;
    }

    ~this()
    {
        free(cast(void*)_storage);
    }

    @disable this(this);

private:
    const(CharType)* _storage = null;
}

/// Semantic function to check that a D string implicitely conveys a
/// termination byte after the slice.
/// (typically those comes from string literals or `stringDup`/`stringIDup`)
const(char)* assumeZeroTerminated(const(char)[] input) pure nothrow @nogc @trusted
{
    assert (input.ptr !is null);

    // Check that the null character is there
    assert(input.ptr[input.length] == '\0');
    return input.ptr;
}