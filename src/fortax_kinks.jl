# Fortax.jl — Kinks module: piecewise-linear budget constraint calculation
# Pure-Julia translation of fortax_kinks.f90
#
# Accessor functor structs are generated from NETTU_SCHEMA and NETAD_SCHEMA,
# so adding a new field to those schemas automatically makes it available
# as a kinks output variable.

module FortaxKinks

using StaticArrays
using ..FortaxTypes
using ..FortaxCalc: calc_net_inc

export kinks_hours, kinks_earn, kinks_ccexp, eval_kinks_hours, eval_kinks_earn, kinks_desc

# ══════════════════════════════════════════════════════════════════════
# Schema-driven accessor generation
#
# We use lightweight functor structs instead of closures/Dict{String,Function}
# so that the core kinks routines can be type-parameterised on the accessor,
# allowing full specialisation and inlining with zero dynamic dispatch.
# ══════════════════════════════════════════════════════════════════════

# --- Generate TU-level accessors from NETTU_SCHEMA ---
for f in NETTU_SCHEMA
    sname = Symbol("_TU_", f.name)
    fname = f.name
    @eval struct $sname end
    @eval @inline (::$sname)(n::Net) = n.tu.$fname
end

# Build tu accessor lookup dict
const _tu_accessors = Dict{String,Any}()
for f in NETTU_SCHEMA
    sname = Symbol("_TU_", f.name)
    _tu_accessors[string(f.name)] = @eval $sname()
end

# --- Generate AD-level accessors from NETAD_SCHEMA ---
for f in NETAD_SCHEMA
    sname = Symbol("_AD_", f.name)
    fname = f.name
    @eval struct $sname{I} end
    @eval @inline (::$sname{I})(n::Net) where I = n.ad[I].$fname
end

# Build per-adult accessor lookup dicts
const _ad1_accessors = Dict{String,Any}()
const _ad2_accessors = Dict{String,Any}()
for f in NETAD_SCHEMA
    sname = Symbol("_AD_", f.name)
    _ad1_accessors[string(f.name)] = @eval $sname{1}()
    _ad2_accessors[string(f.name)] = @eval $sname{2}()
end

@inline function _ad_accessor(field::String, i::Int)
    dict = i == 1 ? _ad1_accessors : _ad2_accessors
    haskey(dict, field) || error("Field '$field' does not exist at level 'ad'")
    return dict[field]
end

# --- Composite accessor: sums multiple signed accessors ---
struct CompositeAccessor{N, Accessors <: NTuple{N, Any}, Signs <: NTuple{N, Int}}
    accessors :: Accessors
    signs     :: Signs
end

@inline function (c::CompositeAccessor{N})(n::Net) where N
    v = 0.0
    @inbounds for i in 1:N
        v += c.signs[i] * c.accessors[i](n)
    end
    return v
end

"""Build a composite accessor functor from taxlevel and taxout specifications."""
function _build_accessor(; taxlevel::String="tu", taxout::Vector{String}=["dispinc"])
    level = lowercase(strip(taxlevel))
    desc_parts = String[]
    accessor_list = []
    sign_list = Int[]

    for (idx, raw) in enumerate(taxout)
        s = strip(raw)
        sign = 1
        if startswith(s, '-')
            sign = -1
            s = strip(s[2:end])
        elseif startswith(s, '+')
            s = strip(s[2:end])
        end
        push!(sign_list, sign)
        field = lowercase(s)

        if level == "tu"
            haskey(_tu_accessors, field) || error("Field '$field' does not exist at level 'tu'")
            push!(accessor_list, _tu_accessors[field])
        elseif level == "ad1"
            push!(accessor_list, _ad_accessor(field, 1))
        elseif level == "ad2"
            push!(accessor_list, _ad_accessor(field, 2))
        else
            error("Unrecognized taxlevel: $level")
        end
        push!(desc_parts, (sign < 0 ? " - " : (idx > 1 ? " + " : "")) * field)
    end

    prefix = level == "tu" ? "tu." : (level == "ad1" ? "ad[1]." : "ad[2].")
    desc = prefix * (length(taxout) > 1 ? "(" * join(desc_parts) * ")" : desc_parts[1])

    N = length(accessor_list)
    acc = CompositeAccessor(
        NTuple{N, Any}(Tuple(accessor_list)),
        NTuple{N, Int}(Tuple(sign_list)),
    )

    return acc, desc
end

# ══════════════════════════════════════════════════════════════════════
# Evaluate a budget constraint at a point
# ══════════════════════════════════════════════════════════════════════

"""
    eval_kinks_hours(bc, hours; hint=nothing) -> (earn, net, mtr, idx)

Evaluate piecewise-linear budget constraint `bc` at given `hours`.
"""
function eval_kinks_hours(bc::BCOut, hours::Float64; hint::Union{Nothing,Int}=nothing)
    n = bc.kinks_num
    i = _locate(bc.kinks_hrs, n, hours, hint)
    wage = bc.kinks_earn[2] / bc.kinks_hrs[2]
    mtr = bc.kinks_mtr[i]
    net = bc.kinks_net[i] + mtr * wage * (hours - bc.kinks_hrs[i])
    earn = wage * hours
    return earn, net, mtr, i
end

"""
    eval_kinks_earn(bc, earn; hint=nothing) -> (hours, net, mtr, idx)

Evaluate piecewise-linear budget constraint `bc` at given `earn`.
"""
function eval_kinks_earn(bc::BCOut, earn::Float64; hint::Union{Nothing,Int}=nothing)
    n = bc.kinks_num
    i = _locate(bc.kinks_earn, n, earn, hint)
    mtr = bc.kinks_mtr[i]
    net = bc.kinks_net[i] + mtr * (earn - bc.kinks_earn[i])
    hrs = bc.kinks_hrs[i]
    return hrs, net, mtr, i
end

"""Binary search or hint-guided search for segment index."""
@inline function _locate(arr, n::Int, val::Float64, hint::Union{Nothing,Int})
    if val >= arr[n]
        return n
    elseif val <= arr[1]
        return 1
    end

    if hint !== nothing
        if val >= arr[hint]
            for j in (hint+1):n
                val < arr[j] && return j - 1
            end
            return n
        else
            for j in (hint-1):-1:1
                val > arr[j] && return j
            end
            return 1
        end
    end

    lo, hi = 1, n
    while lo + 1 < hi
        mid = (lo + hi) ÷ 2
        if val < arr[mid]
            hi = mid
        else
            lo = mid
        end
    end
    return lo
end

# ══════════════════════════════════════════════════════════════════════
# Display
# ══════════════════════════════════════════════════════════════════════

using Printf

function kinks_desc(bc::BCOut; io::IO=stdout)
    println(io)
    println(io, "=" ^ 62)
    println(io, lpad(bc.bc_desc, (62 + length(bc.bc_desc)) ÷ 2))
    println(io, "=" ^ 62)
    @printf(io, "%14s  %14s  %14s  %13s\n", "Hours", "Earnings", "Income", "Rate")
    println(io, "=" ^ 62)
    for i in 1:bc.kinks_num
        mark = abs(bc.kinks_mtr[i]) >= 9.998 ? "*" : ""
        @printf(io, "%14.3f  %14.3f  %14.3f  %13.5f%s\n",
                bc.kinks_hrs[i], bc.kinks_earn[i], bc.kinks_net[i], bc.kinks_mtr[i], mark)
    end
    println(io, "=" ^ 62)
end

# ══════════════════════════════════════════════════════════════════════
# Helpers: build modified Fam without setfields (zero-allocation)
# ══════════════════════════════════════════════════════════════════════

"""Construct a new Fam with adult `ad_idx` replaced by a FamAd with given hrs/earn."""
@inline function _fam_with_ad(fam::Fam, ad_idx::Int, hrs_v::Float64, earn_v::Float64)
    ad1 = fam.ad[1]; ad2 = fam.ad[2]
    if ad_idx == 1
        ad1 = FamAd(ad1.age, ad1.selfemp, hrs_v, earn_v)
    else
        ad2 = FamAd(ad2.age, ad2.selfemp, hrs_v, earn_v)
    end
    Fam(fam.couple, fam.married, fam.ccexp, fam.maint, fam.nkids, fam.kidage,
        fam.nothads, fam.tenure, fam.rent, fam.rentcap, fam.region, fam.ctband,
        fam.banddratio, fam.intdate, SVector(ad1, ad2))
end

"""Construct a new Fam with adult `ad_idx` replaced and ccexp changed."""
@inline function _fam_with_ad_ccexp(fam::Fam, ad_idx::Int, hrs_v::Float64, earn_v::Float64, ccexp_v::Float64)
    ad1 = fam.ad[1]; ad2 = fam.ad[2]
    if ad_idx == 1
        ad1 = FamAd(ad1.age, ad1.selfemp, hrs_v, earn_v)
    else
        ad2 = FamAd(ad2.age, ad2.selfemp, hrs_v, earn_v)
    end
    Fam(fam.couple, fam.married, ccexp_v, fam.maint, fam.nkids, fam.kidage,
        fam.nothads, fam.tenure, fam.rent, fam.rentcap, fam.region, fam.ctband,
        fam.banddratio, fam.intdate, SVector(ad1, ad2))
end

# ══════════════════════════════════════════════════════════════════════
# Core kinks computation (shared bisection algorithm)
# ══════════════════════════════════════════════════════════════════════

"""
    kinks_hours(sys, fam, ad, wage, hours1, hours2;
                taxlevel="tu", taxout=["dispinc"], correct=false) -> BCOut

Compute piecewise-linear budget constraint by varying hours of work.
"""
function kinks_hours(sys::TaxSystem, fam::Fam, ad::Int, wage::Float64,
                     hours1::Float64, hours2::Float64;
                     taxlevel::String="tu", taxout::Vector{String}=["dispinc"],
                     correct::Bool=false)
    accessor, desc = _build_accessor(; taxlevel, taxout)
    return _kinks_core_hours(sys, fam, ad, wage, hours1, hours2, accessor, desc, correct)
end

"""
    kinks_earn(sys, fam, ad, hours, earn1, earn2;
               taxlevel="tu", taxout=["dispinc"], correct=false) -> BCOut

Compute piecewise-linear budget constraint by varying earnings.
"""
function kinks_earn(sys::TaxSystem, fam::Fam, ad::Int, hours::Float64,
                    earn1::Float64, earn2::Float64;
                    taxlevel::String="tu", taxout::Vector{String}=["dispinc"],
                    correct::Bool=false)
    accessor, desc = _build_accessor(; taxlevel, taxout)
    return _kinks_core_earn(sys, fam, ad, hours, earn1, earn2, accessor, desc, correct)
end

"""
    kinks_ccexp(sys, fam, ad, hours, earn, ccexp1, ccexp2;
                taxlevel="tu", taxout=["dispinc"], correct=false) -> BCOut

Compute piecewise-linear budget constraint by varying childcare expenditure.
"""
function kinks_ccexp(sys::TaxSystem, fam::Fam, ad::Int, hours::Float64,
                     earn::Float64, ccexp1::Float64, ccexp2::Float64;
                     taxlevel::String="tu", taxout::Vector{String}=["dispinc"],
                     correct::Bool=false)
    accessor, desc = _build_accessor(; taxlevel, taxout)
    return _kinks_core_ccexp(sys, fam, ad, hours, earn, ccexp1, ccexp2, accessor, desc, correct)
end

# ──────────────────────────────────────────────────────────────────────
# Hours-varying core (type-parameterised on accessor for specialisation)
# ──────────────────────────────────────────────────────────────────────

function _kinks_core_hours(sys::TaxSystem, fam::Fam, ad::Int, wage::Float64,
                           hours1::Float64, hours2::Float64,
                           accessor::F, desc::String, correct::Bool) where F
    mtrtol  = 1.0e-5
    distol  = 1.01
    htol    = 0.00001
    maxstep = 1.0
    minstep = maxstep / 10000.0

    hours2 - hours1 < maxstep && return BCOut()
    hours1 < 0.0 && return BCOut()
    wage < 0.0 && return BCOut()
    ad == 2 && fam.couple == 0 && return BCOut()
    ad < 1 || ad > 2 && return BCOut()

    kinks_hrs  = MVector{maxKinks, Float64}(undef)
    kinks_earn = MVector{maxKinks, Float64}(undef)
    kinks_net  = MVector{maxKinks, Float64}(undef)
    kinks_mtr  = MVector{maxKinks, Float64}(undef)
    kinks_dis  = MVector{maxKinks, Bool}(undef)

    @inline function _eval(hrs_v)
        fam_v = _fam_with_ad(fam, ad, hrs_v, wage * hrs_v)
        net = calc_net_inc(sys, fam_v)
        return accessor(net)
    end

    taxcomp0 = _eval(hours1)

    hrs = hours1 + minstep
    taxcomp1 = _eval(hrs)
    taxrate1 = (taxcomp1 - taxcomp0) / (wage * minstep)

    kinks_hrs[1]  = hours1
    kinks_earn[1] = wage * hours1
    kinks_net[1]  = taxcomp0
    kinks_mtr[1]  = taxrate1
    kinks_dis[1]  = false

    wage == 0.0 && (kinks_mtr[1] = 0.0)

    kinkidx = 2
    taxrate0 = taxrate1
    hrs0 = hours1 + minstep

    while kinkidx < maxKinks
        hrs += maxstep
        hrs > hours2 && break

        taxcomp1 = _eval(hrs)
        taxrate1 = (taxcomp1 - taxcomp0) / (wage * maxstep)

        if wage == 0.0
            taxrate1 = _eval(hrs)
        end

        if abs(taxrate1 - taxrate0) > mtrtol
            hrs_b = hrs; hrs_a = hrs0
            rate_a = taxrate0; temp_a = taxcomp0
            temp_b = 0.0

            while true
                if abs(hrs_b - hrs_a) > htol
                    hrs_mid = 0.5 * (hrs_b + hrs_a)
                    dhrs = 0.5 * (hrs_b - hrs_a)
                    temp_b = _eval(hrs_mid)
                    rate_b = (temp_b - temp_a) / (wage * dhrs)
                    if abs(rate_b - rate_a) > mtrtol
                        hrs_b = hrs_mid
                    else
                        hrs_a = hrs_mid; temp_a = temp_b
                    end
                else
                    temp_a = _eval(hrs_a)
                    temp_b = _eval(hrs_b)
                    dhrs = hrs_b - hrs_a
                    taxrate1 = (temp_b - temp_a) / (wage * dhrs)
                    if abs(taxrate1) > distol
                        kinks_hrs[kinkidx] = hrs_a
                        kinks_earn[kinkidx] = wage * hrs_a
                        kinks_net[kinkidx] = temp_a
                        kinks_dis[kinkidx] = true
                        kinks_mtr[kinkidx] = taxcomp1 > temp_b ? 9.999 : -9.999
                        kinkidx += 1
                    end
                    break
                end
            end

            hrs = hrs_b + minstep
            taxcomp1 = _eval(hrs)
            taxrate1 = (taxcomp1 - temp_b) / (wage * minstep)

            kinks_hrs[kinkidx] = hrs_b
            kinks_earn[kinkidx] = wage * hrs_b
            kinks_net[kinkidx] = temp_b
            kinks_mtr[kinkidx] = taxrate1
            kinks_dis[kinkidx] = false
            wage == 0.0 && (kinks_mtr[kinkidx] = 0.0)
            kinkidx += 1
        end

        taxrate0 = taxrate1; taxcomp0 = taxcomp1; hrs0 = hrs
    end

    if kinkidx < maxKinks
        tc = _eval(hours2)
        kinks_hrs[kinkidx] = hours2
        kinks_earn[kinkidx] = wage * hours2
        kinks_net[kinkidx] = tc
        kinks_mtr[kinkidx] = kinks_mtr[kinkidx - 1]
    end
    kinks_num = min(kinkidx, maxKinks)

    if correct
        _correct_rounding!(kinks_hrs, kinks_earn, kinks_net, kinks_mtr, kinks_dis, kinks_num)
    end

    BCOut(kinks_num,
          SVector(kinks_hrs), SVector(kinks_earn),
          SVector(kinks_net), SVector(kinks_mtr), desc)
end

# ──────────────────────────────────────────────────────────────────────
# Earnings-varying core
# ──────────────────────────────────────────────────────────────────────

function _kinks_core_earn(sys::TaxSystem, fam::Fam, ad::Int, hours::Float64,
                          earn1::Float64, earn2::Float64,
                          accessor::F, desc::String, correct::Bool) where F
    mtrtol  = 1.0e-5
    distol  = 1.01
    etol    = 0.00001
    maxstep = 5.0
    minstep = maxstep / 10000.0

    earn2 - earn1 < maxstep && return BCOut()
    earn1 < 0.0 && return BCOut()
    hours < 0.0 && return BCOut()
    ad == 2 && fam.couple == 0 && return BCOut()
    (ad < 1 || ad > 2) && return BCOut()

    kinks_hrs  = MVector{maxKinks, Float64}(undef)
    kinks_earn = MVector{maxKinks, Float64}(undef)
    kinks_net  = MVector{maxKinks, Float64}(undef)
    kinks_mtr  = MVector{maxKinks, Float64}(undef)
    kinks_dis  = MVector{maxKinks, Bool}(undef)

    fill!(kinks_hrs, hours)

    @inline function _eval(earn_v)
        fam_v = _fam_with_ad(fam, ad, hours, earn_v)
        net = calc_net_inc(sys, fam_v)
        return accessor(net)
    end

    taxcomp0 = _eval(earn1)
    earn = earn1 + minstep
    taxcomp1 = _eval(earn)
    taxrate1 = (taxcomp1 - taxcomp0) / minstep

    kinks_earn[1] = earn1
    kinks_net[1]  = taxcomp0
    kinks_mtr[1]  = taxrate1
    kinks_dis[1]  = false

    kinkidx = 2
    taxrate0 = taxrate1; earn0 = earn1 + minstep; taxcomp0 = taxcomp1

    while kinkidx < maxKinks
        earn += maxstep
        earn > earn2 && break

        taxcomp1 = _eval(earn)
        taxrate1 = (taxcomp1 - taxcomp0) / maxstep

        if abs(taxrate1 - taxrate0) > mtrtol
            earn_b = earn; earn_a = earn0
            rate_a = taxrate0; temp_a = taxcomp0
            temp_b = 0.0

            while true
                if abs(earn_b - earn_a) > etol
                    earn_mid = 0.5 * (earn_b + earn_a)
                    dearn = 0.5 * (earn_b - earn_a)
                    temp_b = _eval(earn_mid)
                    rate_b = (temp_b - temp_a) / dearn
                    if abs(rate_b - rate_a) > mtrtol
                        earn_b = earn_mid
                    else
                        earn_a = earn_mid; temp_a = temp_b
                    end
                else
                    temp_a = _eval(earn_a)
                    temp_b = _eval(earn_b)
                    dearn = earn_b - earn_a
                    taxrate1 = (temp_b - temp_a) / dearn
                    if abs(taxrate1) > distol
                        kinks_earn[kinkidx] = earn_a
                        kinks_net[kinkidx]  = temp_a
                        kinks_dis[kinkidx]  = true
                        kinks_mtr[kinkidx]  = taxcomp1 > temp_b ? 9.999 : -9.999
                        kinkidx += 1
                    end
                    break
                end
            end

            earn = earn_b + minstep
            taxcomp1 = _eval(earn)
            taxrate1 = (taxcomp1 - temp_b) / minstep

            kinks_earn[kinkidx] = earn_b
            kinks_net[kinkidx]  = temp_b
            kinks_mtr[kinkidx]  = taxrate1
            kinks_dis[kinkidx]  = false
            kinkidx += 1
        end

        taxrate0 = taxrate1; taxcomp0 = taxcomp1; earn0 = earn
    end

    if kinkidx < maxKinks
        tc = _eval(earn2)
        kinks_earn[kinkidx] = earn2
        kinks_net[kinkidx]  = tc
        kinks_mtr[kinkidx]  = kinks_mtr[kinkidx - 1]
    end
    kinks_num = min(kinkidx, maxKinks)

    if correct
        _correct_rounding!(kinks_hrs, kinks_earn, kinks_net, kinks_mtr, kinks_dis, kinks_num)
    end

    BCOut(kinks_num,
          SVector(kinks_hrs), SVector(kinks_earn),
          SVector(kinks_net), SVector(kinks_mtr), desc)
end

# ──────────────────────────────────────────────────────────────────────
# Childcare-expenditure-varying core
# ──────────────────────────────────────────────────────────────────────

function _kinks_core_ccexp(sys::TaxSystem, fam::Fam, ad::Int, hours::Float64,
                           earn::Float64, ccexp1::Float64, ccexp2::Float64,
                           accessor::F, desc::String, correct::Bool) where F
    mtrtol  = 1.0e-5
    distol  = 1.50
    etol    = 0.00001
    maxstep = 5.0
    minstep = maxstep / 10000.0

    ccexp2 - ccexp1 < maxstep && return BCOut()
    ccexp1 < 0.0 && return BCOut()
    earn < 0.0 && return BCOut()
    hours < 0.0 && return BCOut()
    ad == 2 && fam.couple == 0 && return BCOut()
    (ad < 1 || ad > 2) && return BCOut()

    kinks_hrs       = MVector{maxKinks, Float64}(undef)
    kinks_earn_arr  = MVector{maxKinks, Float64}(undef)
    kinks_ccexp_arr = MVector{maxKinks, Float64}(undef)
    kinks_net       = MVector{maxKinks, Float64}(undef)
    kinks_mtr       = MVector{maxKinks, Float64}(undef)
    kinks_dis       = MVector{maxKinks, Bool}(undef)

    fill!(kinks_hrs, hours)
    fill!(kinks_earn_arr, earn)

    @inline function _eval(ccexp_v)
        fam_v = _fam_with_ad_ccexp(fam, ad, hours, earn, ccexp_v)
        net = calc_net_inc(sys, fam_v)
        return accessor(net)
    end

    taxcomp0 = _eval(ccexp1)
    ccexp = ccexp1 + minstep
    taxcomp1 = _eval(ccexp)
    taxrate1 = (taxcomp1 - taxcomp0) / minstep

    kinks_ccexp_arr[1] = ccexp1
    kinks_net[1] = taxcomp0
    kinks_mtr[1] = taxrate1
    kinks_dis[1] = false

    kinkidx = 2
    taxrate0 = taxrate1; ccexp0 = ccexp1 + minstep; taxcomp0 = taxcomp1

    while kinkidx < maxKinks
        ccexp += maxstep
        ccexp > ccexp2 && break

        taxcomp1 = _eval(ccexp)
        taxrate1 = (taxcomp1 - taxcomp0) / maxstep

        if abs(taxrate1 - taxrate0) > mtrtol
            ccexp_b = ccexp; ccexp_a = ccexp0
            rate_a = taxrate0; temp_a = taxcomp0
            temp_b = 0.0

            while true
                if abs(ccexp_b - ccexp_a) > etol
                    ccexp_mid = 0.5 * (ccexp_b + ccexp_a)
                    dccexp = 0.5 * (ccexp_b - ccexp_a)
                    temp_b = _eval(ccexp_mid)
                    rate_b = (temp_b - temp_a) / dccexp
                    if abs(rate_b - rate_a) > mtrtol
                        ccexp_b = ccexp_mid
                    else
                        ccexp_a = ccexp_mid; temp_a = temp_b
                    end
                else
                    temp_a = _eval(ccexp_a)
                    temp_b = _eval(ccexp_b)
                    dccexp = ccexp_b - ccexp_a
                    taxrate1 = (temp_b - temp_a) / dccexp
                    if abs(taxrate1) > distol
                        kinks_ccexp_arr[kinkidx] = ccexp_a
                        kinks_net[kinkidx] = temp_a
                        kinks_dis[kinkidx] = true
                        kinks_mtr[kinkidx] = taxcomp1 > temp_b ? 9.999 : -9.999
                        kinkidx += 1
                    end
                    break
                end
            end

            ccexp = ccexp_b + minstep
            taxcomp1 = _eval(ccexp)
            taxrate1 = (taxcomp1 - temp_b) / minstep

            kinks_ccexp_arr[kinkidx] = ccexp_b
            kinks_net[kinkidx] = temp_b
            kinks_mtr[kinkidx] = taxrate1
            kinks_dis[kinkidx] = false
            kinkidx += 1
        end

        taxrate0 = taxrate1; taxcomp0 = taxcomp1; ccexp0 = ccexp
    end

    if kinkidx < maxKinks
        tc = _eval(ccexp2)
        kinks_ccexp_arr[kinkidx] = ccexp2
        kinks_net[kinkidx] = tc
        kinks_mtr[kinkidx] = kinks_mtr[kinkidx - 1]
    end
    kinks_num = min(kinkidx, maxKinks)

    if correct
        for i in 1:kinks_num
            kinks_mtr[i] = round(kinks_mtr[i], digits=5)
            kinks_ccexp_arr[i] = round(kinks_ccexp_arr[i], digits=3)
        end
        kinks_ccexp_arr[1] = round(kinks_ccexp_arr[1], digits=3)
        for i in 2:kinks_num
            if kinks_dis[i - 1]
                kinks_net[i] = round(kinks_net[i], digits=3)
            else
                kinks_net[i] = kinks_net[i - 1] + kinks_mtr[i - 1] * (kinks_ccexp_arr[i] - kinks_ccexp_arr[i - 1])
            end
        end
    end

    BCOut(kinks_num,
          SVector(kinks_hrs), SVector(kinks_ccexp_arr),
          SVector(kinks_net), SVector(kinks_mtr), desc)
end

# ──────────────────────────────────────────────────────────────────────
# Rounding correction
# ──────────────────────────────────────────────────────────────────────

function _correct_rounding!(kinks_hrs, kinks_earn, kinks_net, kinks_mtr, kinks_dis, n)
    for i in 1:n
        kinks_mtr[i]  = round(kinks_mtr[i], sigdigits=10)
        kinks_earn[i] = round(kinks_earn[i], sigdigits=10)
    end
    kinks_earn[1] = round(kinks_earn[1] * 1000.0) / 1000.0
    for i in 2:n
        if kinks_dis[i - 1]
            kinks_net[i] = round(kinks_net[i], sigdigits=10)
        else
            kinks_net[i] = kinks_net[i - 1] + kinks_mtr[i - 1] * (kinks_earn[i] - kinks_earn[i - 1])
        end
    end
end

end # module FortaxKinks
