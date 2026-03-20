# Fortax.jl — Pure Julia UK tax-benefit microsimulation
# Main module: ties all submodules together

module Fortax

include("fortax_types.jl")
include("fortax_read.jl")
include("fortax_calc.jl")
include("fortax_prices.jl")
include("fortax_extra.jl")
include("fortax_kinks.jl")

using .FortaxTypes
using .FortaxRead
using .FortaxCalc
using .FortaxPrices
using .FortaxExtra
using .FortaxKinks

# Re-export the public API

# Types
export TaxSystem, Fam, FamAd, Net, NetAd, NetTU
export IncomeTax, NatIns, ChBen, FamilyCredit, CTC, WTC, NTC
export IncSup, CouncilTax, RebateSys, HBen, CTaxBen, CCBen
export UnivCred, StatePen, BenCap, Extra
export RPIndex, SysIndex, BCOut

# Constants & labels
export maxKids, maxRpi, maxNumAgeRng, maxIncTaxBands, maxNatInsBands
export maxNatInsC4Bands, maxKinks, sysHuge
export lab_bool, lab_ctax, lab_tenure, lab_region, lab
export label_bool, label_ctax, label_tenure, label_region

# Schema
export FieldSpec, _schema, SYS_COMPONENTS
export INCTAX_SCHEMA, NATINS_SCHEMA, CHBEN_SCHEMA, FC_SCHEMA, CTC_SCHEMA
export WTC_SCHEMA, NTC_SCHEMA, INCSUP_SCHEMA, CTAX_SCHEMA, REBATESYS_SCHEMA
export HBEN_SCHEMA, CTAXBEN_SCHEMA, CCBEN_SCHEMA, UC_SCHEMA, STATEPEN_SCHEMA
export BENCAP_SCHEMA, EXTRA_SCHEMA
export FAMAD_SCHEMA, FAM_SCHEMA, NETAD_SCHEMA, NETTU_SCHEMA

# Utility
export setfields

# I/O
export read_system, write_system, load_index, load_sysindex

# Calculation
export calc_net_inc

# Prices
export get_index, uprate_factor, uprate_sys, check_date, get_sys_index, set_index

# Extra
export set_min_amount, abolish_ni_fee, disable_taper_rounding
export fsmin_appamt, taper_matgrant, impose_uc
export fam_desc, net_desc, sys_desc

# Kinks
export kinks_hours, kinks_earn, kinks_ccexp
export eval_kinks_hours, eval_kinks_earn, kinks_desc

end # module Fortax
