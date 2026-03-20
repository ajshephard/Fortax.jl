# Fortax.jl — Extra utilities (schema-driven where applicable)

module FortaxExtra

using StaticArrays
using ..FortaxTypes

using Printf

export set_min_amount, abolish_ni_fee, disable_taper_rounding,
       fsmin_appamt, taper_matgrant, impose_uc,
       fam_desc, net_desc, sys_desc,
       label_bool, label_ctax, label_tenure, label_region

# ─── Schema-driven minimum-amount setter ─────────────────────────────

"""
    set_min_amount(sys::TaxSystem, minamt::Float64) -> TaxSystem

Set the minimum entitlement amount for every benefit whose schema
tags a field with `:minamount`.  Adding a new benefit with a MinAmt
field only requires tagging it `:minamount` in the schema — this
function will pick it up automatically.
"""
function set_min_amount(sys::TaxSystem, minamt::Float64)
    result = sys
    for comp in SYS_COMPONENTS
        schema = _schema(comp.T)
        for f in schema
            if f.attr == :minamount
                # reconstruct the component with that field replaced
                old = getfield(result, comp.field)
                names = fieldnames(typeof(old))
                vals = [fn == f.name ? minamt : getfield(old, fn) for fn in names]
                new_comp = typeof(old)(vals...)
                # reconstruct TaxSystem with the updated component
                snames = fieldnames(TaxSystem)
                svals = [sn == comp.field ? new_comp : getfield(result, sn) for sn in snames]
                result = TaxSystem(svals...)
            end
        end
    end
    return result
end

# ─── Manual utilities (domain-specific logic) ────────────────────────

"""Abolish NI entry fee (pre-1999 systems)."""
function abolish_ni_fee(sys::TaxSystem)
    ni = sys.natins
    ni.numrates < 2 && error("abolish_ni_fee requires numrates >= 2")
    tol_v = 1e-5
    ni.rates[1] <= tol_v && return sys

    amt = ni.rates[1] * ni.bands[1]
    new_rates = setindex(ni.rates, 0.0, 1)
    new_bands = setindex(ni.bands, ni.bands[1] - amt / ni.rates[2], 1)
    setfields(sys; natins = setfields(ni; rates = new_rates, bands = new_bands))
end

"""Disable rounding in taper calculations."""
function disable_taper_rounding(sys::TaxSystem)
    setfields(sys;
        chben  = setfields(sys.chben;  disableTaperRounding   = 1),
        inctax = setfields(sys.inctax; disablePATaperRounding = 1),
    )
end

"""Set FSM-in-applicable-amount flag."""
function fsmin_appamt(sys::TaxSystem, inappamt::Int)
    setfields(sys; extra = setfields(sys.extra; fsminappamt = inappamt))
end

"""Set maternity-grant taper flag."""
function taper_matgrant(sys::TaxSystem, taper::Int)
    setfields(sys; extra = setfields(sys.extra; matgrant = taper))
end

"""
Impose Universal Credit on an existing system, replacing IS, HB, FC/WFTC, NTC
and reconfiguring CTB to operate under UC rules.
"""
function impose_uc(sys::TaxSystem)
    uc_new = setfields(sys.uc;
        MainCou  = sys.incsup.MainCou,
        YngCou   = sys.incsup.YngCou,
        MainSin  = sys.incsup.MainSin,
        YngSin   = sys.incsup.YngSin,
        MinAgeMain = 25,
        FirstKid = sys.ctc.fam + sys.ctc.kid,
        OtherKid = sys.ctc.kid,
        MaxCC1   = sys.wtc.MaxCC1,
        MaxCC2   = sys.wtc.MaxCC2,
        PropCC   = sys.wtc.PropCC,
        MaxAgeCC = sys.wtc.MaxAgeCC,
        doRentCap = 0,
        DisregSinNoKidsHi = 1330.0 / 52.0,
        DisregSinNoKidsLo = 1330.0 / 52.0,
        DisregSinKidsHi   = 8812.0 / 52.0,
        DisregSinKidsLo   = 3159.0 / 52.0,
        DisregCouNoKidsHi = 1330.0 / 52.0,
        DisregCouNoKidsLo = 1330.0 / 52.0,
        DisregCouKidsHi   = 6429.0 / 52.0,
        DisregCouKidsLo   = 2660.0 / 52.0,
        taper     = sys.hben.taper,
        MinAmt    = 0.01 * 12.0 / 52.0,
        doUnivCred = 1,
    )

    bencap_new = setfields(sys.bencap;
        doThruUC  = 1,
        UCEarnThr = 430.0 * 12.0 / 52.0,
    )

    setfields(sys;
        uc       = uc_new,
        bencap   = bencap_new,
        incsup   = setfields(sys.incsup; doIncSup     = 0),
        hben     = setfields(sys.hben;   doHBen       = 0),
        fc       = setfields(sys.fc;     dofamcred    = 0),
        ntc      = setfields(sys.ntc;    donewtaxcred = 0),
        rebatesys = setfields(sys.rebatesys;
            RulesUnderUC   = 1,
            RulesUnderNTC  = 0,
            RulesUnderWFTC = 0,
            RulesUnderFC   = 0,
        ),
    )
end

# ─── Label reverse-lookup ─────────────────────────────────────────────

"""Return the label name string for integer `val` in label set `labsym`,
   or "INVALID VALUE" if not found."""
function _label_str(labsym::Symbol, val::Int)
    labsym === :_ && return nothing
    nt = getfield(lab, labsym)
    for (k, v) in pairs(nt)
        v == val && return string(k)
    end
    return "INVALID VALUE"
end

"""
    label_bool(val::Int) -> String

Convert a boolean-coded integer to its label string ("no" or "yes").
"""
label_bool(val::Int) = _label_str(:bool, val)

"""
    label_ctax(val::Int) -> String

Convert a council tax band integer to its label string (e.g. "banda"…"bandh").
"""
label_ctax(val::Int) = _label_str(:ctax, val)

"""
    label_tenure(val::Int) -> String

Convert a tenure integer to its label string (e.g. "own_outright", "mortgage", …).
"""
label_tenure(val::Int) = _label_str(:tenure, val)

"""
    label_region(val::Int) -> String

Convert a region integer to its label string (e.g. "north_east", "london", …).
"""
label_region(val::Int) = _label_str(:region, val)

# ─── Description display (schema-driven) ─────────────────────────────

"""Centre a string within `width` characters."""
function _str_centre(s::AbstractString, width::Int)
    n = length(s)
    n >= width && return s
    pad_left = div(width - n, 2)
    pad_right = width - n - pad_left
    return " "^pad_left * s * " "^pad_right
end

"""Print a formatted description line for a scalar Int field."""
function _desc_int(io::IO, desc::String, fname::Symbol, val::Int;
                   labsym::Symbol=:_)
    left = isempty(desc) ? string(fname) : desc * " (" * string(fname) * ")"
    if labsym !== :_
        ls = _label_str(labsym, val)
        right = ls * " (" * string(val) * ")"
        @printf(io, "%-40s  %20s\n", left, right)
    else
        @printf(io, "%-40s  %20d\n", left, val)
    end
end

"""Print formatted description lines for an Int array field (up to nval elements)."""
function _desc_int_array(io::IO, desc::String, fname::Symbol, val, nval::Int)
    for ix in 1:nval
        left = isempty(desc) ? string(fname) * "[" * string(ix) * "]" :
               desc * " (" * string(fname) * "[" * string(ix) * "])"
        @printf(io, "%-40s  %20d\n", left, val[ix])
    end
end

"""Print a formatted description line for a scalar Float64 field."""
function _desc_dbl(io::IO, desc::String, fname::Symbol, val::Float64)
    left = isempty(desc) ? string(fname) : desc * " (" * string(fname) * ")"
    @printf(io, "%-40s  %20.4f\n", left, val)
end

"""Print formatted description lines for a Float64 array field."""
function _desc_dbl_array(io::IO, desc::String, fname::Symbol, val, nval::Int)
    for ix in 1:nval
        left = isempty(desc) ? string(fname) * "[" * string(ix) * "]" :
               desc * " (" * string(fname) * "[" * string(ix) * "])"
        @printf(io, "%-40s  %20.4f\n", left, val[ix])
    end
end

"""Print a section header banner."""
function _desc_banner(io::IO, title::String)
    println(io, repeat("=", 62))
    println(io, _str_centre(title, 62))
    println(io, repeat("=", 62))
end

"""Print all fields of a struct using its schema."""
function _desc_fields(io::IO, obj, schema::Tuple)
    for f in schema
        val = getfield(obj, f.name)
        if f.dim > 0  # array field
            nval = f.dimvar === :_ ? f.dim : getfield(obj, f.dimvar)  # won't happen for Net but for Fam
            if f.T === Int
                _desc_int_array(io, f.desc, f.name, val, nval)
            else
                _desc_dbl_array(io, f.desc, f.name, val, nval)
            end
        else  # scalar
            if f.T === Int
                _desc_int(io, f.desc, f.name, val; labsym=f.label)
            else
                _desc_dbl(io, f.desc, f.name, val)
            end
        end
    end
end

"""Print fields of a struct, but look up dimvar on a parent object."""
function _desc_fields_parent(io::IO, obj, schema::Tuple, parent)
    for f in schema
        val = getfield(obj, f.name)
        if f.dim > 0
            nval = f.dimvar === :_ ? f.dim : getfield(parent, f.dimvar)
            if f.T === Int
                _desc_int_array(io, f.desc, f.name, val, nval)
            else
                _desc_dbl_array(io, f.desc, f.name, val, nval)
            end
        else
            if f.T === Int
                _desc_int(io, f.desc, f.name, val; labsym=f.label)
            else
                _desc_dbl(io, f.desc, f.name, val)
            end
        end
    end
end

# ─── sys_desc helpers (different format from fam/net: 5dp, sysHuge, array style) ──

"""Print a sys_desc line for a scalar Int field, with sysHuge check."""
function _sys_desc_int(io::IO, desc::String, fname::Symbol, val::Int;
                       labsym::Symbol=:_)
    left = isempty(desc) ? string(fname) : desc * " (" * string(fname) * ")"
    if val >= sysHuge
        @printf(io, "%-40s  %20s\n", left, "unbounded")
    elseif labsym !== :_
        ls = _label_str(labsym, val)
        right = ls * " (" * string(val) * ")"
        @printf(io, "%-40s  %20s\n", left, right)
    else
        @printf(io, "%-40s  %20d\n", left, val)
    end
end

"""Print a sys_desc line for a scalar Float64 field, with sysHuge check."""
function _sys_desc_dbl(io::IO, desc::String, fname::Symbol, val::Float64)
    left = isempty(desc) ? string(fname) : desc * " (" * string(fname) * ")"
    if val >= sysHuge
        @printf(io, "%-40s  %20s\n", left, "unbounded")
    else
        @printf(io, "%-40s  %20.5f\n", left, val)
    end
end

"""Print sys_desc lines for an Int array: desc on first element, blank on rest."""
function _sys_desc_int_array(io::IO, desc::String, fname::Symbol, val, nval::Int)
    left = isempty(desc) ? string(fname) : desc * " (" * string(fname) * ")"
    for ix in 1:nval
        l = ix == 1 ? left : ""
        v = val[ix]
        if v >= sysHuge
            @printf(io, "%-40s  %20s\n", l, "unbounded")
        else
            @printf(io, "%-40s  %20d\n", l, v)
        end
    end
end

"""Print sys_desc lines for a Float64 array: desc on first element, blank on rest."""
function _sys_desc_dbl_array(io::IO, desc::String, fname::Symbol, val, nval::Int)
    left = isempty(desc) ? string(fname) : desc * " (" * string(fname) * ")"
    for ix in 1:nval
        l = ix == 1 ? left : ""
        v = val[ix]
        if v >= sysHuge
            @printf(io, "%-40s  %20s\n", l, "unbounded")
        else
            @printf(io, "%-40s  %20.5f\n", l, v)
        end
    end
end

"""Print all fields of a system component using its schema (sys_desc style)."""
function _sys_desc_fields(io::IO, obj, schema::Tuple)
    for f in schema
        val = getfield(obj, f.name)
        if f.dim > 0  # array field
            nval = f.dimvar === :_ ? f.dim : getfield(obj, f.dimvar)
            if f.T === Int
                _sys_desc_int_array(io, f.desc, f.name, val, nval)
            else
                _sys_desc_dbl_array(io, f.desc, f.name, val, nval)
            end
        else  # scalar
            if f.T === Int
                _sys_desc_int(io, f.desc, f.name, val; labsym=f.label)
            else
                _sys_desc_dbl(io, f.desc, f.name, val)
            end
        end
    end
end

"""
    sys_desc(sys::TaxSystem; io::IO=stdout, fname::String="")

Display a formatted description of the tax system `sys`.
If `fname` is specified, write to that file instead.
Schema-driven: iterates all system components and their fields.
"""
function sys_desc(sys::TaxSystem; io::IO=stdout, fname::String="")
    if !isempty(fname)
        open(fname, "w") do f
            sys_desc(sys; io=f)
        end
        return
    end

    println(io)
    println(io, repeat("=", 62))
    println(io, _str_centre("sys_desc (" * sys.sysname * "):", 62))
    if !isempty(sys.sysdesc)
        println(io, _str_centre(sys.sysdesc, 62))
    end
    println(io, repeat("=", 62))

    for comp in SYS_COMPONENTS
        schema = _schema(comp.T)
        println(io)
        println(io, uppercase(string(comp.field)) * ":")
        println(io)
        _sys_desc_fields(io, getfield(sys, comp.field), schema)
        println(io)
        println(io, repeat("=", 62))
    end

    nothing
end

"""
    fam_desc(fam::Fam; io::IO=stdout, fname::String="")

Display a formatted description of the family structure `fam`.
If `fname` is specified, write to that file instead.
"""
function fam_desc(fam::Fam; io::IO=stdout, fname::String="")
    if !isempty(fname)
        open(fname, "w") do f
            fam_desc(fam; io=f)
        end
        return
    end

    println(io)
    _desc_banner(io, "fam_desc (FAMILY):")
    _desc_fields(io, fam, FAM_SCHEMA)
    println(io, repeat("=", 62))

    _desc_banner(io, "fam_desc (ADULT 1):")
    _desc_fields(io, fam.ad[1], FAMAD_SCHEMA)
    println(io, repeat("=", 62))

    if fam.couple == 1
        _desc_banner(io, "fam_desc (ADULT 2):")
        _desc_fields(io, fam.ad[2], FAMAD_SCHEMA)
        println(io, repeat("=", 62))
    end

    println(io)
end

"""
    net_desc(net::Net; io::IO=stdout, fname::String="")

Display a formatted description of the net income structure `net`.
If `fname` is specified, write to that file instead.
"""
function net_desc(net::Net; io::IO=stdout, fname::String="")
    if !isempty(fname)
        open(fname, "w") do f
            net_desc(net; io=f)
        end
        return
    end

    println(io)
    _desc_banner(io, "net_desc (TAX UNIT):")
    _desc_fields(io, net.tu, NETTU_SCHEMA)
    println(io, repeat("=", 62))

    _desc_banner(io, "net_desc (ADULT 1):")
    _desc_fields(io, net.ad[1], NETAD_SCHEMA)
    println(io, repeat("=", 62))

    _desc_banner(io, "net_desc (ADULT 2):")
    _desc_fields(io, net.ad[2], NETAD_SCHEMA)
    println(io, repeat("=", 62))

    nothing
end

end # module FortaxExtra
