# TODO: should this be a subtype of Number? causes more ambiguity warnings...
struct Dual{T, P<:Tuple}
    value::T
    partials::P
end

value(d::Dual) = d.value
partials(d::Dual) = d.partials

Base.:(==)(l::Dual, r::Dual) = value(l) == value(r) && partials(l) == partials(r)
Base.isapprox(l::Dual, r::Dual) = value(l) ≈ value(r) && all(isapprox.(partials(l), partials(r)))

function Base.show(io::IO, d::Dual)
    print(io, "Dual($(value(d)), $(partials(d)))")
end

onehot(len, idx) = ntuple((i)->(Int(i==idx)), len)

dualseed(x::T) where T <: Number = Dual(x, (1,))

function dualseed(xs...)
    nseeds = length(xs)
    (Dual(x, onehot(nseeds, i)) for (i, x) in enumerate(xs))
end

"""
    forwardprop(derivative, peturbation)

Propagate a peterbation from a previous step of the computation through a
(possibly partial) derivative.
"""
function forwardprop end

# if we don't have special handling, assumer the derivative is a linar operator
# that can be applied with multiplication. In the common case this could just
# be a real number representing a real-valued derivative. It could also be a
# Jacobian Matrix represented as an `Array`
@inline forwardprop(deriv, peturb) = deriv*peturb

# to give maximum flexibility, allow a derivative to be given as a general
# function. This is useful when there is a more efficient algorithm to apply
# the derivative, e.g. the DFT _could_ be represented by a matmul, but, but we
# use the FFT algorithm for efficiency
# TODO: could this be used for non-commutative partial derivative application?
@inline forwardprop(deriv::Function, peturb) = deriv(peturb)

# Special Rules for propogating complex derivatives using the Wirtinger
# calculus. Note there's a little weirdness going on here because the
# perterbations are stored as a (dw/dz, dw̄/dz) pair, but the partial
# derivatives are stored as a (dw/dz, dw/dz̄) pair.

# These implement the 2x2 Jacobians that are introduced in the Wirtinger
# calculus, because each C-C function generates a C²->C² function when computing
# its partial derivatives. In common cases (holomorphic functions and C-R
# functions, we can take advantage of the fact that these jacobians are only
# half-filled, so we're not actually doing any extra work.)
#
# The general case looks like:
# ⎛df df⎞
# ⎜── ──⎟
# ⎜dz dz̄⎟  ⎛dz⎞
# ⎜     ⎟  ⎜  ⎟
# ⎜df̄ df̄⎟  ⎝dz̄⎠
# ⎜── ──⎟
# ⎝dz dz̄⎠

# but because the partial derivatives are given as df/dz̄, we need to take their
# conjugates to get df̄/dz

# We can determine the type of the output perturbation based on the types of
# the input perturbation and the derivative of the function. Note that "Holo"
# functions and perturbations are represented by regular unwrapped values.
#                       ┌─────────────────────────────────────┐
#                       │         Input Perturbation          │
#                       ├────────┬─────────┬─────────┬────────┤
#                       │ NonHolo│ Holo    │ AntiHolo│ CtoR   │
# ┌───────────┬─────────┼────────┼─────────┼─────────┼────────┤
# │           │ NonHolo │ NonHolo│ NonHolo │ NonHolo │ NonHolo│
# │           ├─────────┼────────┼─────────┼─────────┼────────┤
# │           │ Holo    │ NonHolo│ Holo    │ AntiHolo│ NonHolo│
# │Derivative ├─────────┼────────┼─────────┼─────────┼────────┤
# │           │ AntiHolo│ NonHolo│ AntiHolo│ Holo    │ NonHolo│
# │           ├─────────┼────────┼─────────┼─────────┼────────┤
# │           │ CtoR    │ CtoR   │ CtoR    │ CtoR    │ CtoR   │
# └───────────┴─────────┴────────┴─────────┴─────────┴────────┘

# define the full nonholomorphic forward propagation. We define this separately
# so we can make our dispatch below more straightforward and reduce duplication.
# we should be able to use this for any forward rules that should return a
# NonHolomorphic, and it should still take advantage of special structure of the
# arguments because of the `wirtprimal` and `wirtconj` implementations, which
# should be optimized out when possible.
# note that the derivatives and perturbations are conceptually as
# `(df/dz, df/dz̄)` pairs, but the normal AD multivariate chain rule assumes the
# conjugate derivative is `df̄/dz`. Fortunately those quantities are conjugate
# to each other, so we can convert between them as necessary.

# these two functions define the primal and conjugate components, respectively
@inline _primal_forwardprop(deriv, perturb) =
    forwardprop(wirtprimal(deriv), wirtprimal(perturb)) +
        forwardprop(wirtconj(deriv), conj(wirtconj(perturb)))
@inline _conj_forwardprop(deriv, perturb) =
    forwardprop(wirtconj(deriv), conj(wirtprimal(perturb))) +
        forwardprop(wirtprimal(deriv), wirtconj(perturb))

# now define forwardprop steps for each of the 4 possible result types
@inline _holo_forwardprop(deriv, perturb) =
    _primal_forwardprop(deriv, perturb)

@inline _nonholo_forwardprop(deriv, perturb) =
    NonHolomorphic(_primal_forwardprop(deriv, perturb),
                   _conj_forwardprop(deriv, perturb))

@inline _antiholo_forwardprop(deriv, perturb) =
    AntiHolomorphic(_conj_forwardprop(deriv, perturb))

@inline _ctor_forwardprop(deriv, perturb) =
    CtoR(_primal_forwardprop(deriv, perturb))


@inline forwardprop(deriv, perturb::NonHolomorphic)  = _nonholo_forwardprop(deriv, perturb)
@inline forwardprop(deriv, perturb::AntiHolomorphic) = _antiholo_forwardprop(deriv, perturb)
@inline forwardprop(deriv, perturb::CtoR)            = _nonholo_forwardprop(deriv, perturb)
# forwardprop for non-wirtingers is defined above

@inline forwardprop(deriv::NonHolomorphic, perturb)                  = _nonholo_forwardprop(deriv, perturb)
@inline forwardprop(deriv::NonHolomorphic, perturb::NonHolomorphic)  = _nonholo_forwardprop(deriv, perturb)
@inline forwardprop(deriv::NonHolomorphic, perturb::AntiHolomorphic) = _nonholo_forwardprop(deriv, perturb)
@inline forwardprop(deriv::NonHolomorphic, perturb::CtoR)            = _nonholo_forwardprop(deriv, perturb)

@inline forwardprop(deriv::AntiHolomorphic, perturb)                  = _antiholo_forwardprop(deriv, perturb)
@inline forwardprop(deriv::AntiHolomorphic, perturb::NonHolomorphic)  = _nonholo_forwardprop(deriv, perturb)
# composition is holomorphic, return an unwrapped value
@inline forwardprop(deriv::AntiHolomorphic, perturb::AntiHolomorphic) = _primal_forwardprop(deriv, perturb)
@inline forwardprop(deriv::AntiHolomorphic, perturb::CtoR)            = _nonholo_forwardprop(deriv, perturb)

@inline forwardprop(deriv::CtoR, perturb)                  = _ctor_forwardprop(deriv, perturb)
@inline forwardprop(deriv::CtoR, perturb::NonHolomorphic)  = _ctor_forwardprop(deriv, perturb)
@inline forwardprop(deriv::CtoR, perturb::AntiHolomorphic) = _ctor_forwardprop(deriv, perturb)
@inline forwardprop(deriv::CtoR, perturb::CtoR)            = _ctor_forwardprop(deriv, perturb)

"""
Defines a method to the given unary function that handles dual numbers
"""
macro add_forward_unary(op)
    quote
        function $(esc(op))(d::Dual)
            x = value(d)
            diff, = diffrule($(esc(op)))(x)

            # use Ref to treat diff as a scalar in broadcast
            Dual($(esc(op))(x), forwardprop.(Ref(diff), partials(d)))
        end
    end
end

macro add_forward_binary(op)
    op = esc(op)
    quote
        function $op(l::Number, r::Dual)
            lx, rx = l, value(r)
            _, rdiff = diffrule($op)(lx, rx)

            Dual($op(lx, rx), forwardprop.(Ref(rdiff), partials(r)))
        end
        function $op(l::Dual, r::Number)
            lx, rx = value(l), r
            ldiff, = diffrule($op)(lx, rx)

            Dual($op(lx, rx), forwardprop.(Ref(ldiff), partials(l)))
        end
        function $op(l::Dual, r::Dual)
            lx, rx = value(l), value(r)
            ldiff, rdiff = diffrule($op)(lx, rx)

            # need to call + as a function because macros can't handle dot
            # operators
            Dual($op(lx, rx), (Main.:+).(forwardprop.(Ref(ldiff), partials(l)),
                                         forwardprop.(Ref(rdiff), partials(r))))
        end
    end
end

base_unary_ops = [:sin, :cos, :tan, :log, :real, :imag, :abs2, :conj] #, :fft, :rfft, :ifft, :irfft]
for op in base_unary_ops
    @eval @add_forward_unary Base.$op
end

base_binary_ops = [:+, :-, :*, :/, :^]
for op in base_binary_ops
    @eval @add_forward_binary Base.$op
end
