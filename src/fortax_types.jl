# Fortax.jl — Pure Julia UK tax-benefit microsimulation
# Types module: schema-driven definitions matching the Fortran Fypp approach
#
# The schema tuples (e.g. INCTAX_SCHEMA) are the single source of truth.
# Structs, default constructors, JSON readers, uprating, and accessors
# are all derived from these schemas—adding a field only requires editing
# the schema tuple and (where applicable) the calculation logic.

module FortaxTypes

using StaticArrays

# ─── Exports ──────────────────────────────────────────────────────────

export maxKids, maxRpi, maxSysIndex, maxNumAgeRng, maxIncTaxBands,
       maxNatInsBands, maxNatInsC4Bands, maxKinks, sysHuge,
       len_sysname, len_sysdesc, len_sysindex, len_label, len_labstring, len_bcdesc

export lab_bool, lab_ctax, lab_tenure, lab_region, lab

export FamAd, Fam, NetAd, NetTU, Net
export IncomeTax, NatIns, ChBen, FamilyCredit, CTC, WTC, NTC,
       IncSup, CouncilTax, RebateSys, HBen, CTaxBen, CCBen,
       UnivCred, StatePen, BenCap, Extra, TaxSystem
export RPIndex, SysIndex, BCOut
export setfields

export FieldSpec, _schema, SYS_COMPONENTS
export INCTAX_SCHEMA, NATINS_SCHEMA, CHBEN_SCHEMA, FC_SCHEMA, CTC_SCHEMA,
       WTC_SCHEMA, NTC_SCHEMA, INCSUP_SCHEMA, CTAX_SCHEMA, REBATESYS_SCHEMA,
       HBEN_SCHEMA, CTAXBEN_SCHEMA, CCBEN_SCHEMA, UC_SCHEMA, STATEPEN_SCHEMA,
       BENCAP_SCHEMA, EXTRA_SCHEMA
export FAMAD_SCHEMA, FAM_SCHEMA, NETAD_SCHEMA, NETTU_SCHEMA

# ─── Constants ────────────────────────────────────────────────────────

const maxKids          = 16
const maxRpi           = 1024
const maxSysIndex      = 128
const maxNumAgeRng     = 32
const maxIncTaxBands   = 32
const maxNatInsBands   = 32
const maxNatInsC4Bands = 32
const maxKinks         = 256
const sysHuge          = 1.0e100
const len_sysname      = 64
const len_sysdesc      = 512
const len_sysindex     = 256
const len_label        = 16
const len_labstring    = 64
const len_bcdesc       = 256

# ─── Labels ───────────────────────────────────────────────────────────

const lab_bool   = (no = 0, yes = 1)
const lab_ctax   = (banda = 1, bandb = 2, bandc = 3, bandd = 4,
                    bande = 5, bandf = 6, bandg = 7, bandh = 8)
const lab_tenure = (own_outright = 1, mortgage = 2, part_own = 3,
                    social_renter = 4, private_renter = 5, rent_free = 6, other = 7)
const lab_region = (north_east = 1, north_west = 2, yorks = 3,
                    east_midlands = 4, west_midlands = 5, eastern = 6,
                    london = 7, south_east = 8, south_west = 9,
                    wales = 10, scotland = 11, northern_ireland = 12)
const lab = (bool = lab_bool, ctax = lab_ctax, tenure = lab_tenure, region = lab_region)

# ═══════════════════════════════════════════════════════════════════════
# Schema infrastructure
# ═══════════════════════════════════════════════════════════════════════

"""
    FieldSpec

Single source of truth for one field in a FORTAX schema.

- `name`:    field name (Symbol)
- `T`:       base Julia type (`Int` or `Float64`)
- `attr`:    `:amount`, `:rate`, `:minamount`, `:null`, `:range`, `:scale`
- `desc`:    human-readable description
- `dim`:     0 for scalar, >0 for `SVector{dim, T}`
- `dimvar`:  `:_` = none; otherwise the field that gives the active count
- `label`:   `:_` = none; otherwise label set name (`:bool`, `:ctax`, …)
- `default`: `nothing` → `zero(T)` / `zeros(SVector{…})`; else literal default
"""
struct FieldSpec
    name    :: Symbol
    T       :: DataType
    attr    :: Symbol
    desc    :: String
    dim     :: Int
    dimvar  :: Symbol
    label   :: Symbol
    default :: Any
end

"""Convenience constructor for schema entries."""
F(name::Symbol, T::DataType, attr::Symbol, desc::String="";
  dim::Int=0, dimvar::Symbol=:_, label::Symbol=:_, default=nothing) =
    FieldSpec(name, T, attr, desc, dim, dimvar, label, default)

# ═══════════════════════════════════════════════════════════════════════
# System component schemas  (mirrors includes/system/*.inc)
# ═══════════════════════════════════════════════════════════════════════

const INCTAX_SCHEMA = (
    F(:numbands,                Int,     :range, "Number of income tax bands"),
    F(:pa,                      Float64, :amount, "Personal allowance (PA)"),
    F(:doPATaper,               Int,     :null,  "Taper PA",                     label=:bool),
    F(:disablePATaperRounding,  Int,     :null,  "Disable rounding of PA taper", label=:bool),
    F(:paTaperThresh,           Float64, :amount, "Threshold for PA taper"),
    F(:paTaperRate,             Float64, :rate,   "PA taper rate"),
    F(:mma,                     Float64, :amount),
    F(:ctc,                     Float64, :amount),
    F(:ctcyng,                  Float64, :amount),
    F(:mmarate,                 Float64, :rate),
    F(:ctctaper,                Float64, :rate),
    F(:c4rebate,                Float64, :rate),
    F(:bands, Float64, :amount, "Income tax bands",
      dim=maxIncTaxBands, dimvar=:numbands),
    F(:rates, Float64, :rate, "Income tax rates",
      dim=maxIncTaxBands, dimvar=:numbands),
)

const NATINS_SCHEMA = (
    F(:numrates, Int,     :range),
    F(:c4nrates, Int,     :range),
    F(:c2floor,  Float64, :amount),
    F(:c2rate,   Float64, :amount),
    F(:ceiling,  Float64, :amount),
    F(:rates,   Float64, :rate,   "", dim=maxNatInsBands,   dimvar=:numrates),
    F(:bands,   Float64, :amount, "", dim=maxNatInsBands,   dimvar=:numrates),
    F(:c4rates, Float64, :rate,   "", dim=maxNatInsC4Bands, dimvar=:c4nrates),
    F(:c4bands, Float64, :amount, "", dim=maxNatInsC4Bands, dimvar=:c4nrates),
)

const CHBEN_SCHEMA = (
    F(:doChBen,              Int,     :null, label=:bool),
    F(:basic,                Float64, :amount),
    F(:kid1xtr,              Float64, :amount),
    F(:opf,                  Float64, :amount),
    F(:MatGrantVal,          Float64, :amount),
    F(:MatGrantOnlyFirstKid, Int,     :null, label=:bool),
    F(:doTaper,              Int,     :null, label=:bool),
    F(:disableTaperRounding, Int,     :null, label=:bool),
    F(:taperStart,           Float64, :amount),
    F(:taperRate,            Float64, :rate),
    F(:taperIsIncTax,        Int,     :null, label=:bool),
)

const FC_SCHEMA = (
    F(:dofamcred,    Int,     :null, label=:bool),
    F(:NumAgeRng,    Int,     :range),
    F(:MaxAgeCC,     Int,     :range),
    F(:WFTCMaxAgeCC, Int,     :range),
    F(:adult,        Float64, :amount),
    F(:ftprem,       Float64, :amount),
    F(:hours1,       Float64, :range),
    F(:hours2,       Float64, :range),
    F(:thres,        Float64, :amount),
    F(:taper,        Float64, :rate),
    F(:MaintDisreg,  Float64, :amount),
    F(:MaxCC1,       Float64, :amount),
    F(:MaxCC2,       Float64, :amount),
    F(:WFTCMaxCC1,   Float64, :amount),
    F(:WFTCMaxCC2,   Float64, :amount),
    F(:WFTCPropCC,   Float64, :rate),
    F(:MinAmt,       Float64, :minamount),
    F(:kidagel, Int,     :range,  "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
    F(:kidageu, Int,     :range,  "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
    F(:kidcred, Float64, :amount, "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
)

const CTC_SCHEMA = (
    F(:fam,  Float64, :amount),
    F(:baby, Float64, :amount),
    F(:kid,  Float64, :amount),
)

const WTC_SCHEMA = (
    F(:Basic,         Float64, :amount),
    F(:CouLP,         Float64, :amount),
    F(:FT,            Float64, :amount),
    F(:MinHrsKids,    Float64, :range),
    F(:MinHrsCouKids, Float64, :range),
    F(:MinHrsNoKids,  Float64, :range),
    F(:FTHrs,         Float64, :range),
    F(:MinAgeKids,    Int,     :range),
    F(:MinAgeNoKids,  Int,     :range),
    F(:MaxCC1,        Float64, :amount),
    F(:MaxCC2,        Float64, :amount),
    F(:PropCC,        Float64, :rate),
    F(:MaxAgeCC,      Int,     :range),
    F(:NewDisreg,     Float64, :range),
    F(:NewDisregCon,  Int,     :null, label=:bool),
)

const NTC_SCHEMA = (
    F(:donewtaxcred,    Int,     :null, label=:bool),
    F(:thr1lo,          Float64, :amount),
    F(:thr1hi,          Float64, :amount),
    F(:thr2,            Float64, :amount),
    F(:taper1,          Float64, :rate),
    F(:taper2,          Float64, :rate),
    F(:taperCTCInOneGo, Int,     :null, label=:bool),
    F(:MinAmt,          Float64, :minamount),
)

const INCSUP_SCHEMA = (
    F(:doIncSup,     Int,     :null, label=:bool),
    F(:IncChben,     Int,     :null, label=:bool),
    F(:NumAgeRng,    Int,     :range),
    F(:MainCou,      Float64, :amount),
    F(:YngCou,       Float64, :amount),
    F(:MainLP,       Float64, :amount),
    F(:YngLP,        Float64, :amount),
    F(:MainSin,      Float64, :amount),
    F(:YngSin,       Float64, :amount),
    F(:ValFSM,       Float64, :amount),
    F(:DisregLP,     Float64, :amount),
    F(:DisregSin,    Float64, :amount),
    F(:DisregCou,    Float64, :amount),
    F(:DisregShared, Int,     :null, label=:bool),
    F(:PremFam,      Float64, :amount),
    F(:PremLP,       Float64, :amount),
    F(:hours,        Float64, :range),
    F(:MaintDisreg,  Float64, :amount),
    F(:AgeRngl, Int,     :range,  "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
    F(:AgeRngu, Int,     :range,  "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
    F(:AddKid,  Float64, :amount, "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
)

const CTAX_SCHEMA = (
    F(:docounciltax, Int,     :null, label=:bool),
    F(:bandD,        Float64, :amount),
    F(:SinDis,       Float64, :scale),
    F(:RatioA,       Float64, :scale),
    F(:RatioB,       Float64, :scale),
    F(:RatioC,       Float64, :scale),
    F(:RatioE,       Float64, :scale),
    F(:RatioF,       Float64, :scale),
    F(:RatioG,       Float64, :scale),
    F(:RatioH,       Float64, :scale),
)

const REBATESYS_SCHEMA = (
    F(:RulesUnderFC,   Int,     :null, label=:bool),
    F(:RulesUnderWFTC, Int,     :null, label=:bool),
    F(:RulesUnderNTC,  Int,     :null, label=:bool),
    F(:RulesUnderUC,   Int,     :null, label=:bool),
    F(:NumAgeRng,      Int,     :range),
    F(:Restrict,       Int,     :null, label=:bool),
    F(:docap,          Int,     :null, label=:bool),
    F(:MainCou,        Float64, :amount),
    F(:YngCou,         Float64, :amount),
    F(:MainLP,         Float64, :amount),
    F(:YngLP,          Float64, :amount),
    F(:MainSin,        Float64, :amount),
    F(:YngSin,         Float64, :amount),
    F(:DisregSin,      Float64, :amount),
    F(:DisregLP,       Float64, :amount),
    F(:DisregCou,      Float64, :amount),
    F(:CredInDisregCC, Int,     :null, label=:bool),
    F(:ChbenIsIncome,  Int,     :null, label=:bool),
    F(:PremFam,        Float64, :amount),
    F(:PremLP,         Float64, :amount),
    F(:MaintDisreg,    Float64, :amount),
    F(:MaxCC1,         Float64, :amount),
    F(:MaxCC2,         Float64, :amount),
    F(:MaxAgeCC,       Int,     :range),
    F(:AgeRngl, Int,     :range,  "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
    F(:AgeRngu, Int,     :range,  "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
    F(:AddKid,  Float64, :amount, "", dim=maxNumAgeRng, dimvar=:NumAgeRng),
)

const HBEN_SCHEMA = (
    F(:doHBen, Int,     :null,      "Calculate housing benefit", label=:bool),
    F(:taper,  Float64, :rate,      "Taper rate"),
    F(:MinAmt, Float64, :minamount, "Minimum amount"),
)

const CTAXBEN_SCHEMA = (
    F(:docounciltaxben,  Int,     :null, label=:bool),
    F(:taper,            Float64, :rate),
    F(:doEntitlementCut, Int,     :null, label=:bool),
    F(:entitlementShare, Float64, :rate),
)

const CCBEN_SCHEMA = (
    F(:dopolltax, Int,     :null,  label=:bool),
    F(:taper,     Float64, :rate),
    F(:PropElig,  Float64, :scale),
    F(:MinAmt,    Float64, :minamount),
    F(:CCrate,    Float64, :rate),
)

const UC_SCHEMA = (
    F(:doUnivCred,        Int,     :null, label=:bool),
    F(:MainCou,           Float64, :amount),
    F(:YngCou,            Float64, :amount),
    F(:MainSin,           Float64, :amount),
    F(:YngSin,            Float64, :amount),
    F(:MinAgeMain,        Int,     :range),
    F(:FirstKid,          Float64, :amount),
    F(:OtherKid,          Float64, :amount),
    F(:MaxCC1,            Float64, :amount),
    F(:MaxCC2,            Float64, :amount),
    F(:PropCC,            Float64, :rate),
    F(:MaxAgeCC,          Int,     :range),
    F(:doRentCap,         Int,     :null, label=:bool),
    F(:DisregSinNoKidsHi, Float64, :amount),
    F(:DisregSinNoKidsLo, Float64, :amount),
    F(:DisregSinKidsHi,   Float64, :amount),
    F(:DisregSinKidsLo,   Float64, :amount),
    F(:DisregCouNoKidsHi, Float64, :amount),
    F(:DisregCouNoKidsLo, Float64, :amount),
    F(:DisregCouKidsHi,   Float64, :amount),
    F(:DisregCouKidsLo,   Float64, :amount),
    F(:taper,             Float64, :rate),
    F(:MinAmt,            Float64, :minamount),
)

const STATEPEN_SCHEMA = (
    F(:doStatePen,  Int, :null,  label=:bool),
    F(:PenAgeMan,   Int, :range),
    F(:PenAgeWoman, Int, :range),
)

const BENCAP_SCHEMA = (
    F(:doCap,     Int,     :null, label=:bool),
    F(:doThruUC,  Int,     :null, label=:bool),
    F(:sinNoKids, Float64, :amount),
    F(:sinKids,   Float64, :amount),
    F(:couNoKids, Float64, :amount),
    F(:couKids,   Float64, :amount),
    F(:UCEarnThr, Float64, :amount),
)

const EXTRA_SCHEMA = (
    F(:fsminappamt, Int, :null, label=:bool),
    F(:matgrant,    Int, :null, label=:bool),
    F(:prices,      Int, :null),
)

# ═══════════════════════════════════════════════════════════════════════
# Family & net-income schemas
# ═══════════════════════════════════════════════════════════════════════

const FAMAD_SCHEMA = (
    F(:age,     Int,     :null, "Age",           default=25),
    F(:selfemp, Int,     :null, "Self-employed", label=:bool),
    F(:hrs,     Float64, :null, "Hours-of-work"),
    F(:earn,    Float64, :amount, "Earnings"),
)

const FAM_SCHEMA = (
    F(:couple,     Int,     :null, "Married/cohabiting", label=:bool),
    F(:married,    Int,     :null, "Married",            label=:bool),
    F(:ccexp,      Float64, :amount, "Childcare expenditure"),
    F(:maint,      Float64, :amount, "Maintenance income"),
    F(:nkids,      Int,     :null,   "Number of children"),
    F(:kidage,     Int,     :null,   "Age of children", dim=maxKids, dimvar=:nkids),
    F(:nothads,    Int,     :null,   "Number of other adults"),
    F(:tenure,     Int,     :null,   "Housing tenure",  default=1, label=:tenure),
    F(:rent,       Float64, :amount, "Housing rent"),
    F(:rentcap,    Float64, :amount, "Housing rent cap"),
    F(:region,     Int,     :null,   "Region",          default=1, label=:region),
    F(:ctband,     Int,     :null,   "Council tax band", default=lab_ctax.bandd, label=:ctax),
    F(:banddratio, Float64, :null,   "Council tax band-D ratio", default=1.0),
    F(:intdate,    Int,     :null,   "Interview date",  default=19900101),
)

const NETAD_SCHEMA = (
    F(:taxable,     Float64, :amount, "Taxable income"),
    F(:inctax,      Float64, :amount, "Income tax"),
    F(:natins,      Float64, :amount, "National Insurance"),
    F(:natinsc1,    Float64, :amount, "National Insurance, class 1"),
    F(:natinsc2,    Float64, :amount, "National Insurance, class 2"),
    F(:natinsc4,    Float64, :amount, "National Insurance, class 4"),
    F(:pretaxearn,  Float64, :amount, "Pre-tax earnings"),
    F(:posttaxearn, Float64, :amount, "Post-tax earnings"),
)

const NETTU_SCHEMA = (
    F(:pretaxearn,  Float64, :amount, "Pre-tax earnings"),
    F(:posttaxearn, Float64, :amount, "Post-tax earnings"),
    F(:chben,       Float64, :amount, "Child benefit"),
    F(:matgrant,    Float64, :amount, "Maternity grant"),
    F(:fc,          Float64, :amount, "Family Credit/WFTC"),
    F(:wtc,         Float64, :amount, "Working Tax Credit"),
    F(:ctc,         Float64, :amount, "Child Tax Credit"),
    F(:ccexp,       Float64, :amount, "Childcare expenditure"),
    F(:incsup,      Float64, :amount, "Income Support"),
    F(:hben,        Float64, :amount, "Housing Benefit"),
    F(:polltax,     Float64, :amount, "Community Charge"),
    F(:polltaxben,  Float64, :amount, "Community Charge Benefit"),
    F(:ctax,        Float64, :amount, "Council Tax"),
    F(:ctaxben,     Float64, :amount, "Council Tax Benefit"),
    F(:maxuc,       Float64, :amount, "Universal Credit maximum award"),
    F(:uc,          Float64, :amount, "Universal Credit"),
    F(:dispinc,     Float64, :amount, "Disposable income"),
    F(:pretax,      Float64, :amount, "Pre-tax income"),
    F(:nettax,      Float64, :amount, "Total net tax"),
    F(:chcaresub,   Float64, :amount, "Childcare subsidy"),
    F(:fsm,         Float64, :amount, "Free school meals value"),
    F(:totben,      Float64, :amount, "Total benefits and Tax Credits"),
)

# ═══════════════════════════════════════════════════════════════════════
# Struct generation from schemas
# ═══════════════════════════════════════════════════════════════════════

"""Look up the schema for a generated type (defined via dispatch below)."""
function _schema end

# (TypeName, schema_const_symbol) — order matters for evaluation
const _TYPE_DEFS = [
    # system components
    (:IncomeTax,    :INCTAX_SCHEMA),
    (:NatIns,       :NATINS_SCHEMA),
    (:ChBen,        :CHBEN_SCHEMA),
    (:FamilyCredit, :FC_SCHEMA),
    (:CTC,          :CTC_SCHEMA),
    (:WTC,          :WTC_SCHEMA),
    (:NTC,          :NTC_SCHEMA),
    (:IncSup,       :INCSUP_SCHEMA),
    (:CouncilTax,   :CTAX_SCHEMA),
    (:RebateSys,    :REBATESYS_SCHEMA),
    (:HBen,         :HBEN_SCHEMA),
    (:CTaxBen,      :CTAXBEN_SCHEMA),
    (:CCBen,        :CCBEN_SCHEMA),
    (:UnivCred,     :UC_SCHEMA),
    (:StatePen,     :STATEPEN_SCHEMA),
    (:BenCap,       :BENCAP_SCHEMA),
    (:Extra,        :EXTRA_SCHEMA),
    # family / net
    (:FamAd,        :FAMAD_SCHEMA),
    (:NetAd,        :NETAD_SCHEMA),
    (:NetTU,        :NETTU_SCHEMA),
]

for (tname, schema_sym) in _TYPE_DEFS
    schema = eval(schema_sym)

    # struct fields
    field_exprs = Expr[]
    for f in schema
        ft = f.dim > 0 ? :(SVector{$(f.dim), $(f.T)}) : f.T
        push!(field_exprs, :($(f.name) :: $ft))
    end

    # default values for no-arg constructor
    default_vals = Any[]
    for f in schema
        if f.default !== nothing
            push!(default_vals, f.T(f.default))
        elseif f.dim > 0
            push!(default_vals, :(zeros(SVector{$(f.dim), $(f.T)})))
        else
            push!(default_vals, zero(f.T))
        end
    end

    @eval struct $tname
        $(field_exprs...)
    end
    # FamAd gets a keyword constructor below instead of a positional no-arg one
    if tname != :FamAd
        @eval $tname() = $tname($(default_vals...))
    end

    # dispatch: Type -> schema const
    @eval _schema(::Type{$tname}) = $schema_sym
end

# keyword constructor for FamAd (replaces the no-arg constructor skipped above)
FamAd(; age=25, selfemp=0, hrs=0.0, earn=0.0) = FamAd(age, selfemp, hrs, earn)

# ═══════════════════════════════════════════════════════════════════════
# Composite types (special structure, defined by hand)
# ═══════════════════════════════════════════════════════════════════════

# ─── Fam (FAM_SCHEMA fields + ad vector) ─────────────────────────────

struct Fam
    couple     :: Int
    married    :: Int
    ccexp      :: Float64
    maint      :: Float64
    nkids      :: Int
    kidage     :: SVector{maxKids, Int}
    nothads    :: Int
    tenure     :: Int
    rent       :: Float64
    rentcap    :: Float64
    region     :: Int
    ctband     :: Int
    banddratio :: Float64
    intdate    :: Int
    ad         :: SVector{2, FamAd}
end

"""Pad any indexable collection to an SVector{maxKids, Int}, filling unused slots with 0."""
@inline function _pad_kidage(v)
    buf = MVector{maxKids, Int}(ntuple(_ -> 0, Val(maxKids)))
    n = min(length(v), maxKids)
    for i in 1:n
        buf[i] = Int(v[i])
    end
    return SVector(buf)
end

function Fam(;
    couple     = 0,
    married    = 0,
    ccexp      = 0.0,
    maint      = 0.0,
    nkids      = nothing,
    kidage     = nothing,
    nothads    = 0,
    tenure     = 1,
    rent       = 0.0,
    rentcap    = 0.0,
    region     = 1,
    ctband     = lab_ctax.bandd,
    banddratio = 1.0,
    intdate    = 19900101,
    ad1        = FamAd(),
    ad2        = FamAd(),
    ad         = nothing,
)
    # kidage: accept any indexable (tuple, vector, short SVector, etc.)
    # and pad to SVector{maxKids, Int}
    kidage_sv = kidage === nothing ? zeros(SVector{maxKids, Int}) : _pad_kidage(kidage)

    # nkids: if omitted, infer from kidage length; if no kidage, default 0
    nk = if nkids !== nothing
        nkids
    elseif kidage !== nothing
        min(length(kidage), maxKids)
    else
        0
    end

    advec = ad !== nothing ? ad : SVector(ad1, ad2)
    Fam(couple, married, ccexp, maint, nk, kidage_sv, nothads, tenure,
        rent, rentcap, region, ctband, banddratio, intdate, advec)
end

# ─── Net (ad vector + tu) ────────────────────────────────────────────

struct Net
    ad :: SVector{2, NetAd}
    tu :: NetTU
end

Net() = Net(SVector(NetAd(), NetAd()), NetTU())

# ─── Net arithmetic operators ────────────────────────────────────────

import Base: +, -, *, /

# Generic helpers that apply an op element-wise over all fields of a struct
@generated function _apply_binop(::typeof(+), a::T, b::T) where T
    fields = fieldnames(T)
    args = [:(getfield(a, $(QuoteNode(f))) + getfield(b, $(QuoteNode(f)))) for f in fields]
    return :(T($(args...)))
end

@generated function _apply_binop(::typeof(-), a::T, b::T) where T
    fields = fieldnames(T)
    args = [:(getfield(a, $(QuoteNode(f))) - getfield(b, $(QuoteNode(f)))) for f in fields]
    return :(T($(args...)))
end

@generated function _apply_scalar(::typeof(*), a::T, s::Real) where T
    fields = fieldnames(T)
    args = [:(getfield(a, $(QuoteNode(f))) * s) for f in fields]
    return :(T($(args...)))
end

@generated function _apply_scalar(::typeof(/), a::T, s::Real) where T
    fields = fieldnames(T)
    args = [:(getfield(a, $(QuoteNode(f))) / s) for f in fields]
    return :(T($(args...)))
end

"""Element-wise addition of two `Net` results."""
function +(a::Net, b::Net)
    Net(SVector(_apply_binop(+, a.ad[1], b.ad[1]),
                _apply_binop(+, a.ad[2], b.ad[2])),
        _apply_binop(+, a.tu, b.tu))
end

"""Element-wise subtraction of two `Net` results."""
function -(a::Net, b::Net)
    Net(SVector(_apply_binop(-, a.ad[1], b.ad[1]),
                _apply_binop(-, a.ad[2], b.ad[2])),
        _apply_binop(-, a.tu, b.tu))
end

"""Scale all fields of `Net` by a scalar."""
function *(a::Net, s::Real)
    Net(SVector(_apply_scalar(*, a.ad[1], s),
                _apply_scalar(*, a.ad[2], s)),
        _apply_scalar(*, a.tu, s))
end

*(s::Real, a::Net) = a * s

"""Divide all fields of `Net` by a scalar."""
function /(a::Net, s::Real)
    Net(SVector(_apply_scalar(/, a.ad[1], s),
                _apply_scalar(/, a.ad[2], s)),
        _apply_scalar(/, a.tu, s))
end

# ─── TaxSystem (sysname + sysdesc + all components) ──────────────────

const SYS_COMPONENTS = (
    (field = :inctax,    T = IncomeTax),
    (field = :natins,    T = NatIns),
    (field = :chben,     T = ChBen),
    (field = :fc,        T = FamilyCredit),
    (field = :ctc,       T = CTC),
    (field = :wtc,       T = WTC),
    (field = :ntc,       T = NTC),
    (field = :incsup,    T = IncSup),
    (field = :ctax,      T = CouncilTax),
    (field = :rebatesys, T = RebateSys),
    (field = :hben,      T = HBen),
    (field = :ctaxben,   T = CTaxBen),
    (field = :ccben,     T = CCBen),
    (field = :uc,        T = UnivCred),
    (field = :statepen,  T = StatePen),
    (field = :bencap,    T = BenCap),
    (field = :extra,     T = Extra),
)

# generate TaxSystem struct from SYS_COMPONENTS
let
    sys_fields = [:(sysname :: String), :(sysdesc :: String)]
    sys_defaults = [:(String("")), :(String(""))]
    for c in SYS_COMPONENTS
        push!(sys_fields, :($(c.field) :: $(c.T)))
        push!(sys_defaults, :($(c.T)()))
    end
    @eval struct TaxSystem
        $(sys_fields...)
    end
    @eval TaxSystem() = TaxSystem($(sys_defaults...))
end

# ─── RPIndex ──────────────────────────────────────────────────────────

struct RPIndex
    ndate :: Int
    date  :: Vector{Int}
    index :: Vector{Float64}
end

RPIndex() = RPIndex(0, Int[], Float64[])

# ─── SysIndex ─────────────────────────────────────────────────────────

struct SysIndex
    nsys  :: Int
    date0 :: Vector{Int}
    date1 :: Vector{Int}
    fname :: Vector{String}
end

SysIndex() = SysIndex(0, Int[], Int[], String[])

# ─── BCOut ────────────────────────────────────────────────────────────

struct BCOut
    kinks_num  :: Int
    kinks_hrs  :: SVector{maxKinks, Float64}
    kinks_earn :: SVector{maxKinks, Float64}
    kinks_net  :: SVector{maxKinks, Float64}
    kinks_mtr  :: SVector{maxKinks, Float64}
    bc_desc    :: String
end

BCOut() = BCOut(0, zeros(SVector{maxKinks, Float64}), zeros(SVector{maxKinks, Float64}),
               zeros(SVector{maxKinks, Float64}), zeros(SVector{maxKinks, Float64}), "")

# ═══════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════

"""
    setfields(x; kwargs...)

Return a new instance of the same type as `x`, with the specified fields replaced.
All structs are immutable so this is the idiomatic way to modify.
"""
@generated function setfields(x::T; kwargs...) where T
    fields = fieldnames(T)
    args = [:(get(kwargs, $(QuoteNode(f)), getfield(x, $(QuoteNode(f))))) for f in fields]
    return :(T($(args...)))
end

end # module FortaxTypes
