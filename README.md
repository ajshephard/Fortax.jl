# Fortax.jl — Pure Julia UK Tax-Benefit Microsimulation

Fortax.jl is a pure Julia reimplementation of the [FORTAX](https://github.com/ajshephard/fortax-library) Fortran library for calculating accurate budget constraints based upon the rules of the actual UK tax and benefit system.

The implementation uses immutable structs and `SVector` (from [StaticArrays.jl](https://github.com/JuliaArrays/StaticArrays.jl)) for high performance comparable to the Fortran version. Tax system files are read using [JSON3.jl](https://github.com/quinnj/JSON3.jl).

## Installation

From the Julia REPL, activate the project and install dependencies:
```julia
using Pkg
Pkg.activate("path/to/Fortax.jl")
Pkg.instantiate()
```

## Basic use

```julia
using Fortax
```

To use Fortax.jl, we typically work with three types. First, `TaxSystem` describes the tax system — a number of different system files are provided in the `res/systems/fortax` directory. Second, `Fam` describes the family (tax unit). Third, `Net` contains all the calculated incomes for this family. So, `TaxSystem` and `Fam` are inputs to Fortax, while `Net` is the output.

We can load a tax system using `read_system`. These are saved as JSON files.
```julia
sys = read_system("res/systems/fortax/April06.json")
```
This will load the system and store it in `sys` (of type `TaxSystem`).

A family is constructed using the `Fam` keyword constructor. This contains anything about the family (or tax unit) that is relevant for calculating net incomes — demographics, labour supply, and earnings. For example, to generate a single parent with two children (aged 0 and 4) who is working 20 hours a week, earning 300 pounds, and with child care expenditure of 100 pounds (note that Fortax works with weekly values):
```julia
fam = Fam(
    kidage = (0, 4),
    ccexp  = 100.0,
    ad1    = FamAd(earn = 300.0, hrs = 20.0),
)
```
Child ages are specified as a tuple — `nkids` is automatically inferred from the length of `kidage`, and the ages are zero-padded to the internal `SVector{16,Int}`. Any component of `Fam` that is not set will take a default value. Adult components are set using `ad1` and `ad2` keywords (each of type `FamAd`).

All structs in Fortax.jl are immutable. To modify fields, use `setfields` which returns a new instance with the specified fields changed:
```julia
fam2 = setfields(fam; ccexp = 200.0)
```

The main calculation routine is `calc_net_inc`. This takes the system `sys` (type `TaxSystem`), the family `fam` (type `Fam`), and returns net incomes and income components in a `Net` struct.
```julia
net = calc_net_inc(sys, fam)
```

The components of `net` are accessed as fields. For example, net (disposable) income is `net.tu.dispinc`. `Net` contains a `tu` field (of type `NetTU`) for tax unit level amounts, and an `ad` field (an `SVector{2, NetAd}`) for per-adult amounts.

Key fields of `NetTU`:
| Field | Description |
|---|---|
| `pretaxearn` | Pre-tax earnings |
| `posttaxearn` | Post-tax earnings |
| `chben` | Child Benefit |
| `matgrant` | Maternity grant |
| `fc` | Family Credit / WFTC |
| `wtc` | Working Tax Credit |
| `ctc` | Child Tax Credit |
| `ccexp` | Childcare expenditure |
| `incsup` | Income Support |
| `hben` | Housing Benefit |
| `polltax` | Community Charge |
| `polltaxben` | Community Charge Benefit |
| `ctax` | Council Tax |
| `ctaxben` | Council Tax Benefit |
| `maxuc` | Universal Credit maximum award |
| `uc` | Universal Credit |
| `dispinc` | Disposable income |
| `pretax` | Pre-tax income |
| `nettax` | Total net tax |
| `chcaresub` | Childcare subsidy |
| `fsm` | Free school meals value |
| `totben` | Total benefits and Tax Credits |

Key fields of `NetAd` (accessed via `net.ad[1]` or `net.ad[2]`):
| Field | Description |
|---|---|
| `taxable` | Taxable income |
| `inctax` | Income tax |
| `natins` | National Insurance |
| `natinsc1` | National Insurance, class 1 |
| `natinsc2` | National Insurance, class 2 |
| `natinsc4` | National Insurance, class 4 |
| `pretaxearn` | Pre-tax earnings |
| `posttaxearn` | Post-tax earnings |

Note that amounts in Fortax are at the weekly level. To get annual equivalents, simply multiply by 52.

### Marginal tax rates

To calculate marginal tax rates holding hours-of-work fixed, compute a forward difference:
```julia
sys = read_system("res/systems/fortax/April06.json")

fam = Fam(
    kidage = (0, 4),
    ccexp  = 100.0,
    ad1    = FamAd(earn = 300.0, hrs = 20.0),
)

net1 = calc_net_inc(sys, fam)

dearn = 1e-4
fam2 = setfields(fam; ad = SVector(FamAd(earn = 300.0 + dearn, hrs = 20.0), fam.ad[2]))
net2 = calc_net_inc(sys, fam2)

mtr = (net2.tu.nettax - net1.tu.nettax) / dearn
```

## Piecewise linear budget sets

Fortax.jl can calculate exact piecewise linear representations of the budget constraint as hours or earnings (and other measures) are varied continuously over some interval. This uses the `BCOut` type.

```julia
using Fortax

sys = read_system("res/systems/fortax/April06.json")

# Generate a family (no earnings/hours specified as these will be varied)
fam = Fam(
    kidage = (0, 4),
    ccexp  = 100.0,
)
```

### Varying hours

To calculate the piecewise linear representation of the budget constraint as we vary hours over some interval, use `kinks_hours`. For example, to vary hours from 0 to 50 with a constant hourly wage of 6 pounds:
```julia
bc = kinks_hours(sys, fam, 1, 6.0, 0.0, 50.0)
```
The third argument specifies the adult whose labour supply we are varying (`1` or `2`). When varying the labour supply of an adult in a couple, the other adult takes the values specified in `fam`.

The budget constraint information is stored in `bc` (type `BCOut`). We can print a summary using `kinks_desc`:
```julia
kinks_desc(bc)
```
This describes the piecewise linear representation of the budget constraint (family net income, `net.tu.dispinc` by default) — the rate is the slope of the budget constraint. Fortax correctly identifies the location of hours-of-work discontinuities (due to rules in the UK tax credit system), and encodes positive/negative instances as a rate of (+/-)9.999. `kinks_desc` visually indicates discontinuities using an asterisk next to the rate.

### Evaluating at specific hours

Once the budget constraint has been calculated with `kinks_hours`, it is straightforward to obtain incomes at an arbitrary value of hours over the interval using `eval_kinks_hours`:
```julia
earnings, netincome, rate = eval_kinks_hours(bc, 40.0)
```
The value of `netincome` is the same as `net.tu.dispinc` if we had alternatively done:
```julia
fam40 = Fam(
    kidage = (0, 4),
    ccexp  = 100.0,
    ad1    = FamAd(earn = 240.0, hrs = 40.0),
)
net = calc_net_inc(sys, fam40)
```

### Custom income components

The budget constraint routines are not limited to evaluating the overall net income measure (`net.tu.dispinc`). They can work with any component of `Net` and also calculate arbitrary combinations of income measures. For example, to calculate the total amount of income tax and national insurance of adult 1 when labour supply is varied:
```julia
bc = kinks_hours(sys, fam, 1, 6.0, 0.0, 50.0;
                 taxlevel = "ad1", taxout = ["inctax", "natins"])

kinks_desc(bc)
```
Here `Income` is the combined income tax and National Insurance liability, while `Rate` is the combined marginal tax rate.

### Varying earnings

To vary earnings at fixed hours, use `kinks_earn` and `eval_kinks_earn`:
```julia
bc = kinks_earn(sys, fam, 1, 20.0, 0.0, 500.0)
earnings, netincome, rate = eval_kinks_earn(bc, 300.0)
```

### Varying childcare expenditure

To vary childcare expenditure at fixed hours and earnings, use `kinks_ccexp`:
```julia
bc = kinks_ccexp(sys, fam, 1, 20.0, 300.0, 0.0, 200.0)
```

Whether it is more appropriate to call `calc_net_inc` directly — or to first summarise the entire budget constraint using `kinks_hours`, `kinks_earn`, or `kinks_ccexp` — is application specific.

## Price uprating

Fortax.jl provides routines to manipulate tax and benefit systems. Suppose we start with an existing system file:
```julia
using Fortax

sys = read_system("res/systems/fortax/April06.json")
```

### Manual uprating

To uprate all monetary amounts by a given factor, use `uprate_sys`:
```julia
sys_uprated = uprate_sys(sys, 1.1)
```
This returns a new `TaxSystem` with all monetary amounts multiplied by 1.1.

### Price index uprating

Rather than specifying an uprating factor directly, Fortax can work with a database of price indices. The default database is stored in `res/prices/rpi.csv` which specifies a date and a price index. Price indices use the `RPIndex` type.
```julia
rpi = load_index()
```
This loads the default price index data. Alternative databases can be specified by passing a file path:
```julia
rpi = load_index("path/to/custom_rpi.csv")
```

To obtain the uprating factor from some date `date0` to date `date1`, use `uprate_factor`. Both `date0` and `date1` are integers representing dates in `YYYYMMDD` format:
```julia
factor = uprate_factor(rpi, 20060401, 20100401)
```

To look up the price index at a specific date:
```julia
idx = get_index(rpi, 20060401)
```

### System index

Fortax includes a system index that maps date ranges to system files. This can be loaded with:
```julia
si = load_sysindex()
```

## Describing systems, families, and net incomes

Fortax.jl provides formatted display functions for inspecting the contents of the main data structures:
```julia
sys_desc(sys)       # print all tax system parameters
fam_desc(fam)       # print family description
net_desc(net)       # print net income components
```
All three accept an optional `fname` keyword to write to a file instead of stdout:
```julia
sys_desc(sys; fname = "system_dump.txt")
```

## Writing systems to JSON

To write a `TaxSystem` to a JSON file (the inverse of `read_system`):
```julia
write_system(sys, "my_system.json")
```
This enables round-tripping: `read_system → modify → write_system`.

## Net income arithmetic

`Net` structs support element-wise arithmetic, which is useful for differencing or averaging simulation results:
```julia
diff = net1 - net2          # element-wise subtraction
sum  = net1 + net2          # element-wise addition
scaled = net * 2.0          # scalar multiplication
halved = net / 2.0          # scalar division
avg = (net1 + net2) / 2     # average of two results
```

## System arithmetic

`TaxSystem` structs can be scaled using `*` and `/` operators, which multiply or divide all monetary amounts (`:amount` and `:minamount` fields) while leaving rates, ages, flags, etc. unchanged:
```julia
sys2 = sys * 1.05           # scale up by 5%
sys3 = sys / 2.0            # halve all monetary amounts
sys4 = 1.1 * sys            # commutative
```

## Label functions

Fortax uses integer codes for categorical variables. Label functions convert these to human-readable strings:
```julia
label_bool(1)       # "yes"
label_tenure(2)     # "mortgage"
label_region(7)     # "london"
label_ctax(4)       # "bandd"
```
The label NamedTuples (`lab_bool`, `lab_ctax`, `lab_tenure`, `lab_region`) are also exported for direct use:
```julia
lab_tenure.mortgage  # 2
```

## Extra utilities

Fortax.jl provides several functions for modifying tax systems:

| Function | Description |
|---|---|
| `set_min_amount(sys, amount)` | Set minimum amounts in FC, NTC, HBen, CTaxBen, CCBen and UC |
| `abolish_ni_fee(sys)` | Set NI class 2 floor and rate to zero |
| `disable_taper_rounding(sys)` | Disable rounding in PA taper and ChBen taper |
| `fsmin_appamt(sys)` | Set IS applicable amount equal to FSM value |
| `taper_matgrant(sys)` | Enable maternity grant tapering through child benefit |
| `impose_uc(sys)` | Switch the system to Universal Credit |

All these functions return new `TaxSystem` instances.

Additional utility functions:

| Function | Description |
|---|---|
| `check_date(date)` | Validate a YYYYMMDD integer is a well-formed date |
| `get_sys_index(si, date)` | Look up which system file corresponds to a date |
| `set_index(dates, indices)` | Construct an `RPIndex` from arrays |

## Type reference

| Type | Description |
|---|---|
| `TaxSystem` | Complete tax and benefit system |
| `Fam` | Family / tax unit description |
| `FamAd` | Adult-level family characteristics |
| `Net` | Calculated net incomes (output) |
| `NetTU` | Tax unit level income components |
| `NetAd` | Adult level income components |
| `BCOut` | Budget constraint output |
| `RPIndex` | Retail price index data |
| `SysIndex` | System index (date ranges to files) |
