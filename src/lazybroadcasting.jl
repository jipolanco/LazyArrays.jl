struct LazyArrayStyle{N} <: AbstractArrayStyle{N} end
LazyArrayStyle(::Val{N}) where N = LazyArrayStyle{N}()
LazyArrayStyle{M}(::Val{N}) where {N,M} = LazyArrayStyle{N}()


struct BroadcastArray{T, N, F, Args} <: LazyArray{T, N}
    f::F
    args::Args
end

const BroadcastVector{T,F,Args} = BroadcastArray{T,1,F,Args}
const BroadcastMatrix{T,F,Args} = BroadcastArray{T,2,F,Args}

LazyArray(bc::Broadcasted) = BroadcastArray(bc)

BroadcastArray{T,N,F,Args}(bc::Broadcasted) where {T,N,F,Args} = BroadcastArray{T,N,F,Args}(bc.f,bc.args)
BroadcastArray{T,N}(bc::Broadcasted{Style,Axes,F,Args}) where {T,N,Style,Axes,F,Args} = BroadcastArray{T,N,F,Args}(bc.f,bc.args)
BroadcastArray{T}(bc::Broadcasted{<:Union{Nothing,BroadcastStyle},<:Tuple{Vararg{Any,N}},<:Any,<:Tuple}) where {T,N} =
    BroadcastArray{T,N}(bc)

BroadcastVector(bc::Broadcasted) = BroadcastVector{combine_eltypes(bc.f, bc.args)}(bc)  
BroadcastMatrix(bc::Broadcasted) = BroadcastMatrix{combine_eltypes(bc.f, bc.args)}(bc)

_broadcast2broadcastarray() = ()
_broadcast2broadcastarray(a, b...) = tuple(a, _broadcast2broadcastarray(b...)...)
_broadcast2broadcastarray(a::Broadcasted{DefaultArrayStyle{0}}, b...) = tuple(materialize(a), _broadcast2broadcastarray(b...)...)
_broadcast2broadcastarray(a::Broadcasted, b...) = tuple(BroadcastArray(a), _broadcast2broadcastarray(b...)...)

_BroadcastArray(bc::Broadcasted) = BroadcastArray{combine_eltypes(bc.f, bc.args)}(bc)
BroadcastArray(bc::Broadcasted{S}) where S =
    _BroadcastArray(instantiate(Broadcasted{S}(bc.f, _broadcast2broadcastarray(bc.args...))))

BroadcastArray(f, A, As...) = BroadcastArray(broadcasted(f, A, As...))
BroadcastMatrix(f, A...) = BroadcastMatrix(broadcasted(f, A...))
BroadcastVector(f, A...) = BroadcastVector(broadcasted(f, A...))

BroadcastArray{T,N}(f, A...) where {T,N} = BroadcastArray{T,N,typeof(f),typeof(A)}(f, A)

BroadcastArray(b::BroadcastArray) = b
BroadcastVector(A::BroadcastVector) = A
BroadcastMatrix(A::BroadcastMatrix) = A

broadcasted(A::BroadcastArray) = instantiate(broadcasted(call(A), arguments(A)...))
broadcasted(A::SubArray{<:Any,N,<:BroadcastArray}) where N = instantiate(broadcasted(call(A), arguments(A)...))
Broadcasted(A::BroadcastArray) = broadcasted(A)::Broadcasted
Broadcasted(A::SubArray{<:Any,N,<:BroadcastArray}) where N = broadcasted(A)::Broadcasted

@inline BroadcastArray(A::AbstractArray) = BroadcastArray(call(A), arguments(A)...)

axes(A::BroadcastArray) = axes(broadcasted(A))
size(A::BroadcastArray) = map(length, axes(A))


@propagate_inbounds getindex(A::BroadcastArray{<:Any,N}, kj::Vararg{Int,N}) where N = broadcasted(A)[kj...]




@propagate_inbounds _broadcast_getindex_range(A::Union{Ref,AbstractArray{<:Any,0},Number}, I) = A # Scalar-likes can just ignore all indices
# Everything else falls back to dynamically dropping broadcasted indices based upon its axes
@propagate_inbounds _broadcast_getindex_range(A, I) = A[I]

_broadcastarray_getindex(B::Broadcasted, kr) = BroadcastArray(B.f, map(a -> _broadcast_getindex_range(a,kr), B.args)...)
_broadcastarray_getindex(B::AbstractArray, kr) = B[kr]

getindex(B::BroadcastArray{<:Any,1}, kr::AbstractVector{<:Integer}) = _broadcastarray_getindex(broadcasted(B), kr)
getindex(B::BroadcastArray{<:Any,1}, kr::AbstractUnitRange{<:Integer}) = _broadcastarray_getindex(broadcasted(B), kr) 

copy(bc::Broadcasted{<:LazyArrayStyle}) = BroadcastArray(bc) 

# BroadcastArray are immutable
copy(bc::BroadcastArray) = bc
map(::typeof(copy), bc::BroadcastArray) = bc
copy(bc::AdjOrTrans{<:Any,<:BroadcastArray}) = bc

# Replacement for #18.
# Could extend this to other similar reductions in Base... or apply at lower level? 
# for (fname, op) in [(:sum, :add_sum), (:prod, :mul_prod),
#                     (:maximum, :max), (:minimum, :min),
#                     (:all, :&),       (:any, :|)]
function Base._sum(f, A::BroadcastArray, ::Colon)
    bc = broadcasted(A)
    T = Broadcast.combine_eltypes(f ∘ bc.f, bc.args) 
    out = zero(T)
    @simd for I in eachindex(bc)
        @inbounds out += f(bc[I])
    end
    out
end
function Base._prod(f, A::BroadcastArray, ::Colon)
    bc = broadcasted(A)
    T = Broadcast.combine_eltypes(f ∘ bc.f, bc.args) 
    out = one(T)
    @simd for I in eachindex(bc)
        @inbounds out *= f(bc[I])
    end
    out
end


BroadcastStyle(::Type{<:LazyArray{<:Any,N}}) where N = LazyArrayStyle{N}()
BroadcastStyle(::Type{<:Adjoint{<:Any,<:LazyVector{<:Any}}}) where N = LazyArrayStyle{2}()
BroadcastStyle(::Type{<:Transpose{<:Any,<:LazyVector{<:Any}}}) where N = LazyArrayStyle{2}()
BroadcastStyle(::Type{<:Adjoint{<:Any,<:LazyMatrix{<:Any}}}) where N = LazyArrayStyle{2}()
BroadcastStyle(::Type{<:Transpose{<:Any,<:LazyMatrix{<:Any}}}) where N = LazyArrayStyle{2}()
BroadcastStyle(L::LazyArrayStyle{N}, ::StaticArrayStyle{N}) where N = L
BroadcastStyle(::StaticArrayStyle{N}, L::LazyArrayStyle{N})  where N = L

"""
    BroadcastLayout{F}()

is returned by `MemoryLayout(A)` if a matrix `A` is a `BroadcastArray`.
`F` is the typeof function that broadcast operation is applied.
"""
struct BroadcastLayout{F} <: AbstractLazyLayout end

tuple_type_memorylayouts(::Type{I}) where I<:Tuple = MemoryLayout.(I.parameters)
tuple_type_memorylayouts(::Type{Tuple{A}}) where {A} = (MemoryLayout(A),)
tuple_type_memorylayouts(::Type{Tuple{A,B}}) where {A,B} = (MemoryLayout(A),MemoryLayout(B))
tuple_type_memorylayouts(::Type{Tuple{A,B,C}}) where {A,B,C} = (MemoryLayout(A),MemoryLayout(B),MemoryLayout(C))

broadcastlayout(::Type{F}, _...) where F = BroadcastLayout{F}()
MemoryLayout(::Type{BroadcastArray{T,N,F,Args}}) where {T,N,F,Args} = 
    broadcastlayout(F, tuple_type_memorylayouts(Args)...)

_copyto!(_, ::BroadcastLayout, dest::AbstractArray{<:Any,N}, bc::AbstractArray{<:Any,N}) where N = 
    copyto!(dest, broadcasted(bc))    
## scalar-range broadcast operations ##
# Ranges already support smart broadcasting
for op in (+, -, big)
    @eval begin
        broadcasted(::LazyArrayStyle{1}, ::typeof($op), r::AbstractRange) =
            broadcast(DefaultArrayStyle{1}(), $op, r)
    end
end

for op in (-, +, *, /)
    @eval broadcasted(::LazyArrayStyle{1}, ::typeof($op), r::AbstractRange, x::Real) =
        broadcast(DefaultArrayStyle{1}(), $op, r, x)
end

for op in (-, +, *, \)
    @eval broadcasted(::LazyArrayStyle{1}, ::typeof($op), x::Real, r::AbstractRange) =
        broadcast(DefaultArrayStyle{1}(), $op, x, r)
end


broadcasted(::LazyArrayStyle{N}, op, r::AbstractFill{T,N}) where {T,N} =
    broadcast(DefaultArrayStyle{N}(), op, r)
broadcasted(::LazyArrayStyle{N}, op, r::AbstractFill{T,N}, x::Number) where {T,N} =
    broadcast(DefaultArrayStyle{N}(), op, r, x)
broadcasted(::LazyArrayStyle{N}, op, x::Number, r::AbstractFill{T,N}) where {T,N} =
    broadcast(DefaultArrayStyle{N}(), op, x, r)
broadcasted(::LazyArrayStyle{N}, op, r::AbstractFill{T,N}, x::Ref) where {T,N} =
    broadcast(DefaultArrayStyle{N}(), op, r, x)
broadcasted(::LazyArrayStyle{N}, op, x::Ref, r::AbstractFill{T,N}) where {T,N} =
    broadcast(DefaultArrayStyle{N}(), op, x, r)    
broadcasted(::LazyArrayStyle{N}, op, r1::AbstractFill{T,N}, r2::AbstractFill{V,N}) where {T,V,N} =
    broadcast(DefaultArrayStyle{N}(), op, r1, r2)

broadcasted(::LazyArrayStyle{N}, ::typeof(*), a::Zeros{T,N}, b::Zeros{V,N}) where {T,V,N} =
    broadcast(DefaultArrayStyle{N}(), *, a, b)
broadcasted(::LazyArrayStyle{N}, ::typeof(*), a::AbstractArray{T,N}, b::Zeros{V,N}) where {T,V,N} =
    broadcast(DefaultArrayStyle{N}(), *, a, b)
broadcasted(::LazyArrayStyle{N}, ::typeof(*), a::Zeros{T,N}, b::AbstractArray{V,N}) where {T,V,N} =
    broadcast(DefaultArrayStyle{N}(), *, a, b)
broadcasted(::LazyArrayStyle{N}, ::typeof(*), a::Broadcasted, b::Zeros{V,N}) where {V,N} =
    broadcast(DefaultArrayStyle{N}(), *, a, b)
broadcasted(::LazyArrayStyle{N}, ::typeof(*), a::Zeros{T,N}, b::Broadcasted) where {T,N} =
    broadcast(DefaultArrayStyle{N}(), *, a, b)


###
# support
###

_broadcast_colsupport(ax, ::Tuple{}, A, j) = ax[1]
_broadcast_colsupport(ax, ::Tuple{<:Any}, A, j) = colsupport(A,j)
_broadcast_colsupport(ax, Aax::Tuple{OneTo{Int},<:Any}, A, j) = length(Aax[1]) == 1 ? ax[1] : colsupport(A,j)
_broadcast_colsupport(ax, ::Tuple{<:Any,<:Any}, A, j) = colsupport(A,j)
_broadcast_rowsupport(ax, ::Tuple{}, A, j) = ax[2]
_broadcast_rowsupport(ax, ::Tuple{<:Any}, A, j) = ax[2]
_broadcast_rowsupport(ax, Aax::Tuple{<:Any,OneTo{Int}}, A, j) = length(Aax[2]) == 1 ? ax[2] : rowsupport(A,j)
_broadcast_rowsupport(ax, ::Tuple{<:Any,<:Any}, A, j) = rowsupport(A,j)

colsupport(lay::BroadcastLayout{typeof(*)}, A, j) = intersect(_broadcast_colsupport.(Ref(axes(A)), axes.(arguments(lay,A)), arguments(lay,A), Ref(j))...)
rowsupport(lay::BroadcastLayout{typeof(*)}, A, j) = intersect(_broadcast_rowsupport.(Ref(axes(A)), axes.(arguments(lay,A)), arguments(lay,A), Ref(j))...)

for op in (:+, :-)
    @eval begin
        rowsupport(lay::BroadcastLayout{typeof($op)}, A, j) = convexunion(_broadcast_rowsupport.(Ref(axes(A)), axes.(arguments(lay,A)), arguments(lay,A), Ref(j))...)
        colsupport(lay::BroadcastLayout{typeof($op)}, A, j) = convexunion(_broadcast_colsupport.(Ref(axes(A)), axes.(arguments(lay,A)), arguments(lay,A), Ref(j))...)
    end
end


###
# SubArray
###

call(b::BroadcastLayout, a::SubArray) = call(b, parent(a))

sublayout(b::BroadcastLayout, _) = b


_broadcastviewinds(::Tuple{}, inds) = ()
_broadcastviewinds(sz, inds) = 
    tuple(isone(sz[1]) ? OneTo(sz[1]) : inds[1], _broadcastviewinds(tail(sz), tail(inds))...)

_broadcastview(a, inds) = view(a, _broadcastviewinds(size(a), inds)...)
_broadcastview(a::Number, inds) = a

function _broadcast_sub_arguments(V)
    args = arguments(parent(V))
    _broadcastview.(args, Ref(parentindices(V)))
end
arguments(b::BroadcastLayout, V::SubArray) = _broadcast_sub_arguments(V)

###
# Transpose
###

call(b::BroadcastLayout, a::AdjOrTrans) = call(b, parent(a))

transposelayout(b::BroadcastLayout) = b
arguments(b::BroadcastLayout, A::Adjoint) = map(adjoint, arguments(b, parent(A)))
arguments(b::BroadcastLayout, A::Transpose) = map(transpose, arguments(b, parent(A)))
