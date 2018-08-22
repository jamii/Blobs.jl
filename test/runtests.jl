module TestBlobs

using Blobs
using Test

struct Foo
    x::Int64
    y::Float32 # tests conversion and alignment
end

# Blob

blob = Blob{Int64}(Libc.malloc(16), 8)
@test_nowarn blob[]
@test_throws BoundsError (blob+1)[]
if Base.JLOptions().check_bounds == 0
    # @inbounds only kicks in if compiled
    f1(blob) = @inbounds (blob+1)[]
    f1(blob)
end

foo = Blobs.malloc_and_init(Foo)
foo.x[] = 1
@test foo.x[] == 1
foo.y[] = 2.5
@test foo.y[] == 2.5
@test foo[] == Foo(1,2.5)
# test interior pointers
@test foo == foo
@test pointer(foo.y) == pointer(foo) + sizeof(Int64)

# nested Blob

bfoo = Blobs.malloc_and_init(Blob{Foo})
foo = bfoo[]
foo.x[] = 1
@test foo.x[] == 1

# BlobVector

@test Blobs.self_size(BlobVector{Int64}) == 16

data = Blob{Int64}(Libc.malloc(sizeof(Int64) * 4), sizeof(Int64) * 3)
bv = BlobVector{Int64}(data, 4)
@test_nowarn bv[3]
@test_throws BoundsError bv[4]
if Base.JLOptions().check_bounds == 0
    f2(bv) = @inbounds bv[4]
    f2(bv)
end

bbv = Blobs.malloc_and_init(BlobVector{Foo}, 3)
bv = bbv[]
bv[2] = Foo(2, 2.2)
@test bv[2] == Foo(2, 2.2)
@test bbv[2][] == Foo(2, 2.2)
@test length(bv) == 3
bv[1] = Foo(1, 1.1)
bv[3] = Foo(3, 3.3)
# test iteration
@test collect(bv) == [Foo(1,1.1), Foo(2,2.2), Foo(3,3.3)]
# test interior pointers
@test pointer(bbv[2]) - pointer(bv.data) == Blobs.self_size(Foo)

# BlobBitVector

@test Blobs.self_size(BlobBitVector) == 16
@test Blobs.child_size(BlobBitVector, 1) == 8*1
@test Blobs.child_size(BlobBitVector, 64*3) == 8*3
@test Blobs.child_size(BlobBitVector, 64*3 + 1) == 8*4

data = Blob{UInt64}(Libc.malloc(sizeof(UInt64)*4), sizeof(UInt64)*3)
bv = BlobBitVector(data, 64*4)
@test_nowarn bv[64*3]
@test_throws BoundsError bv[64*3 + 1]
if Base.JLOptions().check_bounds == 0
    f3(bv) = @inbounds bv[64*3 + 1]
    f3(bv)
end

bbv = Blobs.malloc_and_init(BlobBitVector, 3)
bv = bbv[]
bv[2] = true
@test bv[2] == true
@test bbv[2][] == true
@test length(bv) == 3
bv[1] = false
bv[3] = false
# test iteration
@test collect(bv) == [false, true, false]
fill!(bv, false)
@test collect(bv) == [false, false, false]
# test interior pointers
bv2 = bbv[2]
@test bv2[] == false
bv2[] = true
@test bv2[] == true
@test bv[2] == true

# BlobString

@test Blobs.self_size(BlobString) == 16

data = Blob{UInt8}(Libc.malloc(8), 8)
@test_nowarn BlobString(data, 8)[8]
# pretty much any access to a unicode string touches beginning and end
@test_throws BoundsError BlobString(data, 16)[8]
# @inbounds doesn't work for strings - too much work to propagate

# test strings and unicode
s = "普通话/普通話"
bbs = Blobs.malloc_and_init(BlobString, s)
bs = bbs[]
@test unsafe_string(pointer(bs), sizeof(bs)) == s
@test bs == s
@test repr(bs) == repr(s)
@test collect(bs) == collect(s)
@test findfirst(bs, "通") == findfirst(s, "通")
@test findlast(bs, "通") == findlast(s, "通")

# test right-to-left
s = "سلام"
bbs = Blobs.malloc_and_init(BlobString, s)
bs = bbs[]
@test unsafe_string(pointer(bs), sizeof(bs)) == s
@test bs == s
@test repr(bs) == repr(s)
@test collect(bs) == collect(s)
@test findfirst(bs, "ا") == findfirst(s, "ا")
@test findlast(bs, "ا") == findlast(s, "ا")

# test string conversions

@test isbitstype(typeof(bs))
@test String(bs) isa String
@test String(bs) == s

println(s)
println("Testing: $s")

# test string slices

s = "aye bee sea"
bbs = Blobs.malloc_and_init(BlobString, s)
bs = bbs[]
@test bs[5:7] isa BlobString
@test bs[5:7] == "bee"

# sketch of paged pmas

struct PackedMemoryArray{K,V}
     keys::BlobVector{K}
     values::BlobVector{V}
     mask::BlobBitVector
     count::Int
     #...other stuff
end

function Blobs.child_size(::Type{PackedMemoryArray{K,V}}, length::Int64) where {K,V}
    T = PackedMemoryArray{K,V}
    +(Blobs.child_size(fieldtype(T, :keys), length),
      Blobs.child_size(fieldtype(T, :values), length),
      Blobs.child_size(fieldtype(T, :mask), length))
  end

function Blobs.init(pma::Blob{PackedMemoryArray{K,V}}, free::Blob{Nothing}, length::Int64) where {K,V}
    free = Blobs.init(pma.keys, free, length)
    free = Blobs.init(pma.values, free, length)
    free = Blobs.init(pma.mask, free, length)
    fill!(pma.mask[], false)
    pma.count[] = 0
    free
end

pma = Blobs.malloc_and_init(PackedMemoryArray{Int64, Float32}, 3)
@test pma.count[] == 0
@test pma.keys.length[] == 3
# tests fill!
@test !any(pma.mask[])
# tests pointer <-> offset conversion
@test unsafe_load(convert(Ptr{Int64}, pointer(pma)), 1) == Blobs.self_size(PackedMemoryArray{Int64, Float32})
# tests nested interior pointers
pma2 = pma.mask[2]
@test pma2[] == false
pma2[] = true
@test pma2[] == true
@test pma.mask[2][] == true

# test api works ok with varying sizes

struct Quux
    x::BlobVector{Int}
    y::Float64
end

struct Bar
    a::Int
    b::BlobBitVector
    c::Bool
    d::BlobVector{Float64}
    e::Blob{Quux}
end

@test Blobs.self_size(Bar) == 8 + 16 + 1 + 16 + 8 # Blob{Quux} is smaller in the blob

function Blobs.child_size(::Type{Quux}, x_len::Int64, y::Float64)
    T = Quux
    +(Blobs.child_size(fieldtype(T, :x), x_len))
end

function Blobs.child_size(::Type{Bar}, b_len::Int64, c::Bool, d_len::Int64, x_len::Int64, y::Float64)
    T = Bar
    +(Blobs.child_size(fieldtype(T, :b), b_len),
      Blobs.child_size(fieldtype(T, :d), d_len),
      Blobs.child_size(fieldtype(T, :e), x_len, y))
end

function Blobs.init(quux::Blob{Quux}, free::Blob{Nothing}, x_len::Int64, y::Float64)
    free = Blobs.init(quux.x, free, x_len)
    quux.y[] = y
    free
end

function Blobs.init(bar::Blob{Bar}, free::Blob{Nothing}, b_len::Int64, c::Bool, d_len::Int64, x_len::Int64, y::Float64)
    free = Blobs.init(bar.b, free, b_len)
    free = Blobs.init(bar.d, free, d_len)
    free = Blobs.init(bar.e, free, x_len, y)
    bar.c[] = c
    free
end

bar = Blobs.malloc_and_init(Bar, 10, false, 20, 15, 1.5)
quux = bar.e[]

@test length(bar.b[]) == 10
@test bar.c[] == false
@test length(bar.d[]) == 20
@test length(quux.x[]) == 15
@test quux.y[] == 1.5

end
