# Fortax.jl — Pure Julia UK tax-benefit microsimulation
# Prices module: price index operations and schema-driven system uprating

module FortaxPrices

using ..FortaxTypes

export get_index, uprate_factor, uprate_sys, check_date, get_sys_index, set_index

# ─── Price index lookup ──────────────────────────────────────────────

"""
    set_index(dates::AbstractVector{Int}, indices::AbstractVector{Float64}) -> RPIndex

Construct an `RPIndex` programmatically from arrays of YYYYMMDD dates
and corresponding index values.  If the arrays exceed `maxRpi`, only
the first `maxRpi` entries are used (with a warning).
"""
function set_index(dates::AbstractVector{Int}, indices::AbstractVector{<:Real})
    length(dates) == length(indices) ||
        error("set_index: dates and indices must have the same length")
    n = length(dates)
    if n > maxRpi
        @warn "set_index: truncating to maxRpi=$maxRpi entries (got $n)"
        n = maxRpi
    end
    return RPIndex(n, collect(Int, dates[1:n]), collect(Float64, indices[1:n]))
end

# ─── Price index value lookup ────────────────────────────────────────

"""
    get_index(rpi::RPIndex, date::Int) -> Float64

Return the price index value for the given YYYYMMDD date.
Exploits the monthly structure of the data for O(1) lookup.
"""
@inline function get_index(rpi::RPIndex, date::Int)
    rpi.ndate == 0 && return 0.0
    date < rpi.date[1] && return 0.0
    date > rpi.date[end] && return 0.0

    year   = date ÷ 10000
    month  = (date - year * 10000) ÷ 100
    year1  = rpi.date[1] ÷ 10000
    month1 = (rpi.date[1] - year1 * 10000) ÷ 100
    idx = (year - year1) * 12 + month - month1 + 1

    (idx < 1 || idx > rpi.ndate) && return 0.0
    return rpi.index[idx]
end

"""
    uprate_factor(rpi::RPIndex, date0::Int, date1::Int) -> Float64

Return the uprating factor from `date0` prices to `date1` prices.
"""
@inline function uprate_factor(rpi::RPIndex, date0::Int, date1::Int)
    return get_index(rpi, date1) / get_index(rpi, date0)
end

# ─── Schema-driven component uprating ────────────────────────────────

"""
    _uprate_component(comp::T, factor) -> T

Return a new component with `:amount` and `:minamount` fields scaled by `factor`.
Fields with `:rate`, `:null`, `:range`, `:scale`, etc. are left unchanged.

Uses `@generated` so the schema is resolved at compile time, producing
code equivalent to the hand-written version with zero dynamic dispatch.
"""
@generated function _uprate_component(comp::T, factor::Float64) where T
    schema = _schema(T)
    args = Expr[]
    for f in schema
        access = Expr(:., :comp, QuoteNode(f.name))
        if f.attr == :amount || f.attr == :minamount
            if f.dim > 0
                push!(args, :($access .* factor))
            else
                push!(args, :($access * factor))
            end
        else
            push!(args, access)
        end
    end
    return :(T($(args...)))
end

# ─── System uprating ─────────────────────────────────────────────────

"""
    uprate_sys(sys::TaxSystem, factor::Float64; newdate::Union{Int,Nothing}=nothing) -> TaxSystem

Return a new `TaxSystem` with monetary amounts scaled by `factor`.
Rates, ages, flags, hours thresholds, and scale ratios are NOT scaled.
Driven entirely by schema attributes — fields tagged `:amount` or
`:minamount` are multiplied; everything else is left unchanged.
"""
function uprate_sys(sys::TaxSystem, factor::Float64; newdate::Union{Int,Nothing}=nothing)
    # Uprate each component via the @generated helper
    components = map(SYS_COMPONENTS) do comp
        _uprate_component(getfield(sys, comp.field), factor)
    end

    # Extra.prices gets special treatment: set to newdate if given
    extra_uprated = components[end]
    if newdate !== nothing
        extra_uprated = setfields(extra_uprated; prices = newdate)
    end

    return TaxSystem(sys.sysname, sys.sysdesc,
                     components[1:end-1]..., extra_uprated)
end

# ─── Date validation ──────────────────────────────────────────────────

"""
    check_date(date::Int) -> Bool

Validate that a YYYYMMDD integer is a well-formed calendar date.
"""
function check_date(date::Int)
    year  = date ÷ 10000
    month = (date - year * 10000) ÷ 100
    day   = date - (date ÷ 100) * 100

    maxday = if month in (1, 3, 5, 7, 8, 10, 12)
        31
    elseif month in (4, 6, 9, 11)
        30
    elseif month == 2
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0) ? 29 : 28
    else
        0
    end

    return year >= 0 && 1 <= month <= 12 && 1 <= day <= maxday
end

# ─── System index lookup ──────────────────────────────────────────────

"""
    get_sys_index(sysindex::SysIndex, date::Int) -> (filepath::String, sysnum::Int)

Look up which tax system file corresponds to YYYYMMDD `date`.
Returns the file path (e.g. `"systems/fortax/April10.json"`) and the
1-based index within the `SysIndex`.
"""
function get_sys_index(sysindex::SysIndex, date::Int)
    sysindex.nsys == 0 && error("system index file is not in memory")
    check_date(date) || error("invalid date in get_sys_index: $date")

    for i in 1:sysindex.nsys
        if date >= sysindex.date0[i] && date <= sysindex.date1[i]
            filepath = "systems/fortax/" * sysindex.fname[i] * ".json"
            return (filepath, i)
        end
    end

    error("get_sys_index: date $date not contained in sysindex")
end

# ─── Operator overloads: sys * factor, factor * sys, sys / factor ─────

import Base: *, /

"""
    sys::TaxSystem * factor -> TaxSystem

Return a new `TaxSystem` with all monetary `:amount` and `:minamount`
fields scaled by `factor`.  Rates, ages, flags, etc. are unchanged.
Equivalent to `uprate_sys(sys, factor)` but without `newdate` handling.
"""
function *(sys::TaxSystem, factor::Real)
    f = Float64(factor)
    components = map(SYS_COMPONENTS) do comp
        _uprate_component(getfield(sys, comp.field), f)
    end
    return TaxSystem(sys.sysname, sys.sysdesc, components...)
end

*(factor::Real, sys::TaxSystem) = sys * factor

"""
    sys::TaxSystem / factor -> TaxSystem

Return a new `TaxSystem` with all monetary amounts divided by `factor`.
"""
/(sys::TaxSystem, factor::Real) = sys * (1.0 / Float64(factor))

end # module FortaxPrices
