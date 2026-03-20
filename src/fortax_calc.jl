# Fortax.jl — Pure Julia UK tax-benefit microsimulation
# Calc module: main calculation engine (pure-Julia translation of fortax_calc.f90)
# All functions are pure: they take immutable data and return new immutable results.

module FortaxCalc

using StaticArrays
using ..FortaxTypes

export calc_net_inc

const tol = 0.0

# ──────────────────────────────────────────────────────────────────────
# INCOME TAX
# ──────────────────────────────────────────────────────────────────────

"""Compute taxable earnings for both adults. Returns updated NetAd pair."""
@inline function _tearn(sys::TaxSystem, fam::Fam, ad1::NetAd, ad2::NetAd)
    it = sys.inctax

    # Adult 1 personal allowance
    if it.doPATaper == 1
        over = max(fam.ad[1].earn - it.paTaperThresh, 0.0)
        if over > tol
            pa1 = max(it.pa - over * it.paTaperRate, 0.0)
            if it.disablePATaperRounding == 0
                pa1 = ceil(pa1 * 52.0) / 52.0
            end
        else
            pa1 = it.pa
        end
    else
        pa1 = it.pa
    end
    taxable1 = max(fam.ad[1].earn - pa1, 0.0)

    # Adult 2 personal allowance
    if fam.couple == 1
        if it.doPATaper == 1
            over = max(fam.ad[2].earn - it.paTaperThresh, 0.0)
            if over > tol
                pa2 = max(it.pa - over * it.paTaperRate, 0.0)
                if it.disablePATaperRounding == 0
                    pa2 = ceil(pa2 * 52.0) / 52.0
                end
            else
                pa2 = it.pa
            end
        else
            pa2 = it.pa
        end
        taxable2 = max(fam.ad[2].earn - pa2, 0.0)
    else
        taxable2 = 0.0
    end

    # C4 rebate
    if it.c4rebate > tol
        if ad1.natinsc4 > tol
            taxable1 = max(taxable1 - it.c4rebate * ad1.natinsc4, 0.0)
        end
        if fam.couple == 1 && ad2.natinsc4 > tol
            taxable2 = max(taxable2 - it.c4rebate * ad2.natinsc4, 0.0)
        end
    end

    # MCA/APA pre-Apr 94 (as allowance)
    if it.mma > tol && it.mmarate <= tol
        if fam.couple == 0 && fam.nkids > 0
            taxable1 = max(taxable1 - it.mma, 0.0)
        elseif fam.couple == 1 && (fam.married == 1 || fam.nkids > 0)
            if fam.ad[1].earn >= fam.ad[2].earn
                taxable1 -= it.mma
                if taxable1 < 0.0
                    taxable2 = max(taxable2 + taxable1, 0.0)
                    taxable1 = 0.0
                end
            else
                taxable2 -= it.mma
                if taxable2 < 0.0
                    taxable1 = max(taxable1 + taxable2, 0.0)
                    taxable2 = 0.0
                end
            end
        end
    end

    ad1 = NetAd(taxable1, ad1.inctax, ad1.natins, ad1.natinsc1, ad1.natinsc2, ad1.natinsc4,
                ad1.pretaxearn, ad1.posttaxearn)
    ad2 = NetAd(taxable2, ad2.inctax, ad2.natins, ad2.natinsc1, ad2.natinsc2, ad2.natinsc4,
                ad2.pretaxearn, ad2.posttaxearn)
    return ad1, ad2
end

"""Income tax for one adult, given taxable income."""
@inline function _inctax_amount(sys::TaxSystem, taxable::Float64)
    it = sys.inctax
    tax = 0.0
    if taxable > tol && it.numbands > 0
        # 1st band
        tax += min(taxable, it.bands[1]) * it.rates[1]
        # 2nd to penultimate bands
        if it.numbands > 2
            for j in 2:(it.numbands - 1)
                tax += max(min(taxable - it.bands[j-1], it.bands[j] - it.bands[j-1]), 0.0) * it.rates[j]
            end
        end
        # Last band
        if it.numbands > 1
            tax += max(taxable - it.bands[it.numbands - 1], 0.0) * it.rates[it.numbands]
        end
    end
    return tax
end

"""Children's tax credit (CTC in old sense, pre-2003)."""
@inline function _taxafterctc(sys::TaxSystem, fam::Fam, tax1::Float64, tax2::Float64,
                              taxable1::Float64, taxable2::Float64)
    it = sys.inctax
    if it.ctc > tol && fam.nkids > 0
        yngkid = minimum(@view fam.kidage[1:fam.nkids])
        if yngkid < 16
            ctc_val = it.ctc
            if yngkid == 0
                ctc_val += it.ctcyng
            end
            # Primary earner
            if fam.couple == 0
                pe = 1
            else
                pe = fam.ad[1].earn >= fam.ad[2].earn ? 1 : 2
            end
            if pe == 1
                if taxable1 > it.bands[it.numbands - 1]
                    ctc_val = max(ctc_val - it.ctctaper * (taxable1 - it.bands[it.numbands - 1]), 0.0)
                end
                tax1 -= ctc_val
                if tax1 < 0.0
                    if fam.couple == 1
                        tax2 = max(tax2 + tax1, 0.0)
                    end
                    tax1 = 0.0
                end
            else
                if taxable2 > it.bands[it.numbands - 1]
                    ctc_val = max(ctc_val - it.ctctaper * (taxable2 - it.bands[it.numbands - 1]), 0.0)
                end
                tax2 -= ctc_val
                if tax2 < 0.0
                    if fam.couple == 1
                        tax1 = max(tax1 + tax2, 0.0)
                    end
                    tax2 = 0.0
                end
            end
        end
    end
    return tax1, tax2
end

"""Post-Apr-94 MCA/APA (reduces tax due)."""
@inline function _taxaftermca(sys::TaxSystem, fam::Fam, tax1::Float64, tax2::Float64)
    it = sys.inctax
    if it.mma > tol && it.mmarate > tol
        if fam.couple == 0 && fam.nkids > 0
            tax1 = max(tax1 - it.mma * it.mmarate, 0.0)
        elseif fam.couple == 1 && (fam.married == 1 || fam.nkids > 0)
            if fam.ad[1].earn >= fam.ad[2].earn
                tax1 -= it.mma * it.mmarate
                if tax1 < 0.0
                    tax2 = max(tax2 + tax1, 0.0)
                    tax1 = 0.0
                end
            else
                tax2 -= it.mma * it.mmarate
                if tax2 < 0.0
                    tax1 = max(tax1 + tax2, 0.0)
                    tax2 = 0.0
                end
            end
        end
    end
    return tax1, tax2
end

# ──────────────────────────────────────────────────────────────────────
# NATIONAL INSURANCE
# ──────────────────────────────────────────────────────────────────────

@inline function _natins(sys::TaxSystem, fam::Fam, ad_idx::Int)
    ni = sys.natins
    earn = fam.ad[ad_idx].earn
    selfemp = fam.ad[ad_idx].selfemp

    natinsc1 = 0.0
    natinsc2 = 0.0
    natinsc4 = 0.0

    if selfemp == 0 && ni.numrates > 0
        # Class 1
        if earn >= ni.bands[1] - tol
            natinsc1 = ni.bands[1] * ni.rates[1]
            if ni.numrates > 1
                for j in 2:ni.numrates
                    natinsc1 += max(min(earn - ni.bands[j-1], ni.bands[j] - ni.bands[j-1]), 0.0) * ni.rates[j]
                end
            end
        end
    elseif selfemp == 1 && ni.c4nrates > 0
        # Class 2
        if earn >= ni.c2floor - tol
            natinsc2 = ni.c2rate
        end
        # Class 4
        natinsc4 = min(max(earn, 0.0), ni.c4bands[1]) * ni.c4rates[1]
        if ni.c4nrates > 2
            for j in 2:(ni.c4nrates - 1)
                natinsc4 += max(min(earn - ni.c4bands[j-1], ni.c4bands[j] - ni.c4bands[j-1]), 0.0) * ni.c4rates[j]
            end
        end
        if ni.c4nrates > 1
            natinsc4 += max(earn - ni.c4bands[ni.c4nrates - 1], 0.0) * ni.c4rates[ni.c4nrates]
        end
    end

    natins = natinsc1 + natinsc2 + natinsc4
    return natins, natinsc1, natinsc2, natinsc4
end

# ──────────────────────────────────────────────────────────────────────
# INCOME SUPPORT
# ──────────────────────────────────────────────────────────────────────

@inline function _is_appamt(sys::TaxSystem, fam::Fam)
    is = sys.incsup
    appamt = 0.0

    if fam.couple == 0
        if fam.nkids > 0
            appamt = fam.ad[1].age < 18 ? (is.YngLP + is.PremFam + is.PremLP) :
                                          (is.MainLP + is.PremFam + is.PremLP)
        else
            appamt = fam.ad[1].age < 25 ? is.YngSin : is.MainSin
        end
    else
        if fam.ad[1].age < 18 && fam.ad[2].age < 18
            appamt = is.YngCou
        else
            appamt = is.MainCou
        end
        if fam.nkids > 0
            appamt += is.PremFam
        end
    end

    # Child additions
    if fam.nkids > 0
        for i in 1:fam.nkids
            for j in 1:is.NumAgeRng
                if fam.kidage[i] >= is.AgeRngl[j] && fam.kidage[i] <= is.AgeRngu[j]
                    appamt += is.AddKid[j]
                    break
                end
            end
        end
    end

    return appamt
end

@inline function _is_disreg(sys::TaxSystem, fam::Fam)
    is = sys.incsup
    if fam.couple == 0
        return fam.nkids > 0 ? is.DisregLP : is.DisregSin
    else
        return is.DisregCou
    end
end

@inline function _incsup(sys::TaxSystem, fam::Fam,
                          posttaxearn_tu::Float64, posttaxearn1::Float64, posttaxearn2::Float64,
                          chben::Float64, fc::Float64, wtc::Float64, matgrant_in::Float64)
    is = sys.incsup

    if fam.couple == 1
        maxage = max(fam.ad[1].age, fam.ad[2].age)
        maxhrs = max(fam.ad[1].hrs, fam.ad[2].hrs)
    else
        maxage = fam.ad[1].age
        maxhrs = fam.ad[1].hrs
    end

    incsup_val = 0.0
    matgrant_val = matgrant_in

    if (maxage >= 18 || fam.nkids > 0) && maxhrs < is.hours - tol
        yngkid = fam.nkids > 0 ? minimum(@view fam.kidage[1:fam.nkids]) : -1

        appamt = _is_appamt(sys, fam)
        disreg = _is_disreg(sys, fam)

        othinc = if is.IncChben == 1
            chben + fc + wtc
        else
            fc + wtc
        end

        # FSM in applicable amount
        if sys.extra.fsminappamt == 1
            for i in 1:fam.nkids
                if fam.kidage[i] > 4
                    appamt += is.ValFSM
                end
            end
        end

        # Maternity grant in IS
        MatGrInIS = 0.0
        if sys.extra.matgrant == 1 && yngkid == 0
            for i in 1:fam.nkids
                if fam.kidage[i] == 0
                    MatGrInIS += sys.chben.MatGrantVal / 52.0
                end
            end
            appamt += MatGrInIS
        end

        maint_disreg = fam.nkids > 0 ? is.MaintDisreg : 0.0

        if fam.couple == 0 || is.DisregShared == 1
            incsup_val = max(appamt - max(posttaxearn_tu - disreg, 0.0) -
                            max(fam.maint - maint_disreg, 0.0) - othinc, 0.0)
        else
            incsup_val = max(appamt - max(posttaxearn1 - 0.5 * disreg, 0.0) -
                            max(posttaxearn2 - 0.5 * disreg, 0.0) -
                            max(fam.maint - maint_disreg, 0.0) - othinc, 0.0)
        end

        # Re-assign maternity grant
        if sys.extra.matgrant == 1 && yngkid == 0
            matgrant_val = min(incsup_val, MatGrInIS)
            incsup_val = max(0.0, incsup_val - MatGrInIS)
        end
    end

    return incsup_val, matgrant_val
end

# ──────────────────────────────────────────────────────────────────────
# COUNCIL TAX / POLL TAX
# ──────────────────────────────────────────────────────────────────────

@inline function _ctax(sys::TaxSystem, fam::Fam)
    ct = sys.ctax
    ct.bandD <= tol && return 0.0

    nliabbu = 0
    fam.ad[1].age >= 18 && (nliabbu = 1)
    fam.couple == 1 && fam.ad[2].age >= 18 && (nliabbu += 1)
    nliabbu == 0 && return 0.0

    nliabhh = nliabbu + fam.nothads
    fracbu = nliabbu / nliabhh

    ratio = if fam.ctband == lab_ctax.banda
        ct.RatioA
    elseif fam.ctband == lab_ctax.bandb
        ct.RatioB
    elseif fam.ctband == lab_ctax.bandc
        ct.RatioC
    elseif fam.ctband == lab_ctax.bandd
        1.0
    elseif fam.ctband == lab_ctax.bande
        ct.RatioE
    elseif fam.ctband == lab_ctax.bandf
        ct.RatioF
    elseif fam.ctband == lab_ctax.bandg
        ct.RatioG
    elseif fam.ctband == lab_ctax.bandh
        ct.RatioH
    else
        1.0
    end

    if nliabhh == 1
        return ct.bandD * (1.0 - ct.SinDis) * fam.banddratio * ratio
    else
        return ct.bandD * fam.banddratio * ratio * fracbu
    end
end

@inline function _polltax(sys::TaxSystem, fam::Fam)
    sys.ccben.CCrate <= tol && return 0.0
    nliable = 0
    fam.ad[1].age >= 18 && (nliable = 1)
    fam.couple == 1 && fam.ad[2].age >= 18 && (nliable += 1)
    return sys.ccben.CCrate * nliable
end

# ──────────────────────────────────────────────────────────────────────
# REBATE SYSTEM (HB, CTB, CCB preliminary calculations)
# ──────────────────────────────────────────────────────────────────────

@inline function _hb_appamt(sys::TaxSystem, fam::Fam, maxuc::Float64)
    rb = sys.rebatesys
    if rb.RulesUnderUC == 1
        return maxuc
    end

    appamt = 0.0
    if fam.couple == 0
        if fam.nkids > 0
            appamt = fam.ad[1].age < 18 ? (rb.YngLP + rb.PremFam + rb.PremLP) :
                                          (rb.MainLP + rb.PremFam + rb.PremLP)
        else
            appamt = fam.ad[1].age < 25 ? rb.YngSin : rb.MainSin
        end
    else
        if fam.ad[1].age < 18 && fam.ad[2].age < 18
            appamt = rb.YngCou
        else
            appamt = rb.MainCou
        end
        if fam.nkids > 0
            appamt += rb.PremFam
        end
    end

    if fam.nkids > 0
        for i in 1:fam.nkids
            for j in 1:rb.NumAgeRng
                if fam.kidage[i] >= rb.AgeRngl[j] && fam.kidage[i] <= rb.AgeRngu[j]
                    appamt += rb.AddKid[j]
                    break
                end
            end
        end
    end

    return appamt
end

@inline function _std_disreg(sys::TaxSystem, fam::Fam)
    rb = sys.rebatesys
    if fam.couple == 0
        return fam.nkids > 0 ? rb.DisregLP : rb.DisregSin
    else
        return rb.DisregCou
    end
end

@inline function _ft_disreg(sys::TaxSystem, fam::Fam, fc_val::Float64)
    rb = sys.rebatesys
    ft_disreg = 0.0

    if rb.RulesUnderFC == 1
        if sys.fc.ftprem > tol && fam.nkids > 0 && fc_val > tol
            if fam.couple == 0
                fam.ad[1].hrs >= sys.fc.hours2 - tol && (ft_disreg = sys.fc.ftprem)
            else
                (fam.ad[1].hrs >= sys.fc.hours2 - tol || fam.ad[2].hrs >= sys.fc.hours2 - tol) &&
                    (ft_disreg = sys.fc.ftprem)
            end
        end
    end

    if rb.RulesUnderWFTC == 1
        if sys.fc.ftprem > tol && fam.nkids > 0
            if fam.couple == 0
                fam.ad[1].hrs >= sys.fc.hours2 - tol && (ft_disreg = sys.fc.ftprem)
            else
                (fam.ad[1].hrs >= sys.fc.hours2 - tol || fam.ad[2].hrs >= sys.fc.hours2 - tol) &&
                    (ft_disreg = sys.fc.ftprem)
            end
        end
    end

    if rb.RulesUnderNTC == 1
        w = sys.wtc
        if w.NewDisregCon == 0
            if fam.nkids > 0
                if fam.couple == 1
                    if (fam.ad[1].hrs >= w.MinHrsKids - tol || fam.ad[2].hrs >= w.MinHrsKids - tol) &&
                       (fam.ad[1].hrs + fam.ad[2].hrs >= w.FTHrs - tol)
                        ft_disreg = w.FT
                    end
                else
                    fam.ad[1].hrs >= w.FTHrs - tol && (ft_disreg = w.FT)
                end
            else
                if fam.couple == 1
                    ((fam.ad[1].hrs >= w.MinHrsNoKids - tol && fam.ad[1].age >= w.MinAgeNoKids) ||
                     (fam.ad[2].hrs >= w.MinHrsNoKids - tol && fam.ad[2].age >= w.MinAgeNoKids)) &&
                        (ft_disreg = w.FT)
                else
                    (fam.ad[1].hrs >= w.MinHrsNoKids - tol && fam.ad[1].age >= w.MinAgeNoKids) &&
                        (ft_disreg = w.FT)
                end
            end
        else
            if fam.nkids > 0
                if fam.couple == 1
                    (fam.ad[1].hrs >= w.MinHrsKids - tol || fam.ad[2].hrs >= w.MinHrsKids - tol) &&
                        (ft_disreg = w.NewDisreg)
                else
                    fam.ad[1].hrs >= w.MinHrsKids - tol && (ft_disreg = w.NewDisreg)
                end
            else
                if fam.couple == 1
                    (fam.ad[1].hrs >= w.MinHrsNoKids - tol || fam.ad[2].hrs >= w.MinHrsNoKids - tol) &&
                        (ft_disreg = w.NewDisreg)
                else
                    fam.ad[1].hrs >= w.MinHrsNoKids - tol && (ft_disreg = w.NewDisreg)
                end
            end
        end
    end

    return ft_disreg
end

@inline function _chcare_disreg(sys::TaxSystem, fam::Fam)
    rb = sys.rebatesys
    rb.MaxCC1 <= tol && return 0.0
    fam.nkids == 0 && return 0.0
    fam.ccexp <= tol && return 0.0

    elig = false
    if rb.RulesUnderFC == 1 || rb.RulesUnderWFTC == 1
        if fam.couple == 1
            fam.ad[1].hrs >= sys.fc.hours1 - tol && fam.ad[2].hrs >= sys.fc.hours1 - tol && (elig = true)
        else
            fam.ad[1].hrs >= sys.fc.hours1 - tol && (elig = true)
        end
    end
    if rb.RulesUnderNTC == 1
        if fam.couple == 1
            fam.ad[1].hrs >= sys.wtc.MinHrsKids - tol && fam.ad[2].hrs >= sys.wtc.MinHrsKids - tol && (elig = true)
        else
            fam.ad[1].hrs >= sys.wtc.MinHrsKids - tol && (elig = true)
        end
    end

    nkidscc = count(i -> fam.kidage[i] < rb.MaxAgeCC, 1:fam.nkids)

    if elig && nkidscc > 0
        if nkidscc == 1
            return min(fam.ccexp, rb.MaxCC1)
        else
            return rb.MaxCC2 > tol ? min(fam.ccexp, rb.MaxCC2) : min(fam.ccexp, rb.MaxCC1)
        end
    end
    return 0.0
end

@inline function _maint_disreg(sys::TaxSystem, fam::Fam)
    return fam.nkids > 0 ? sys.rebatesys.MaintDisreg : 0.0
end

@inline function _rebate_disreg(sys::TaxSystem, fam::Fam,
                                 posttaxearn_tu::Float64, fc::Float64, wtc::Float64,
                                 ctc::Float64, uc::Float64, chben::Float64,
                                 appamt::Float64, disregStd::Float64, disregFT::Float64,
                                 disregCC::Float64, disregMnt::Float64)
    rb = sys.rebatesys

    if rb.RulesUnderUC == 1
        return max(posttaxearn_tu + uc - appamt, 0.0)
    end

    if rb.CredInDisregCC == 1
        disregCC1 = 0.0
        disregCC2 = ctc - disregCC
        disregCC3 = 0.0
    else
        disregCC1 = disregCC
        disregCC2 = 0.0
        disregCC3 = ctc
    end

    chben_inc = rb.ChbenIsIncome == 1 ? chben : 0.0

    if rb.RulesUnderWFTC == 1 || rb.RulesUnderNTC == 1
        return max(max(max(max(posttaxearn_tu - disregStd - disregCC1, 0.0) +
                          fc + wtc - disregFT, 0.0) + disregCC2, 0.0) +
                   max(fam.maint - disregMnt, 0.0) + chben_inc + disregCC3 - appamt, 0.0)
    elseif rb.RulesUnderFC == 1
        return max(max(max(max(posttaxearn_tu - disregStd - disregCC1, 0.0) +
                          max(fc + wtc - disregFT, 0.0), 0.0) + disregCC2, 0.0) +
                   max(fam.maint - disregMnt, 0.0) + chben_inc + disregCC3 - appamt, 0.0)
    end
    return 0.0
end

@inline function _hben(sys::TaxSystem, fam::Fam, incsup::Float64, disregRebate::Float64)
    fam.rent <= 0.0 && return 0.0

    eligrent = fam.rent
    if sys.rebatesys.docap == 1 && fam.tenure == lab_tenure.private_renter
        eligrent = min(fam.rent, fam.rentcap)
    end

    hben_val = if incsup > tol
        eligrent
    else
        max(eligrent - disregRebate * sys.hben.taper, 0.0)
    end

    hben_val < sys.hben.MinAmt && (hben_val = 0.0)
    return hben_val
end

@inline function _ctaxben(sys::TaxSystem, fam::Fam, ctax_val::Float64, incsup::Float64,
                           disregRebate::Float64)
    maxage = fam.couple == 1 ? max(fam.ad[1].age, fam.ad[2].age) : fam.ad[1].age
    (maxage < 18 || ctax_val <= tol) && return 0.0

    maxctb = ctax_val
    rb = sys.rebatesys
    ct = sys.ctax

    if fam.ctband > lab_ctax.bande && rb.Restrict == 1
        maxctb *= if fam.ctband == lab_ctax.bandf
            ct.RatioE / ct.RatioF
        elseif fam.ctband == lab_ctax.bandg
            ct.RatioE / ct.RatioG
        elseif fam.ctband == lab_ctax.bandh
            ct.RatioE / ct.RatioH
        else
            1.0
        end
    end

    if sys.ctaxben.doEntitlementCut == 1
        if fam.region != lab_region.wales && fam.region != lab_region.scotland
            maxctb *= sys.ctaxben.entitlementShare
        end
    end

    if incsup > tol
        return maxctb
    else
        return max(maxctb - disregRebate * sys.ctaxben.taper, 0.0)
    end
end

@inline function _polltaxben(sys::TaxSystem, fam::Fam, polltax_val::Float64,
                              incsup::Float64, disregRebate::Float64)
    maxage = fam.couple == 1 ? max(fam.ad[1].age, fam.ad[2].age) : fam.ad[1].age
    maxage < 18 && return 0.0

    eligcc = polltax_val * sys.ccben.PropElig
    if incsup > tol
        return eligcc
    else
        ptb = max(eligcc - disregRebate * sys.ccben.taper, 0.0)
        return ptb < sys.ccben.MinAmt ? 0.0 : ptb
    end
end

# ──────────────────────────────────────────────────────────────────────
# TAX CREDITS (NTC / FC)
# ──────────────────────────────────────────────────────────────────────

@inline function _max_ctc_fam(sys::TaxSystem, fam::Fam)
    fam.nkids == 0 && return 0.0
    yngkid = minimum(@view fam.kidage[1:fam.nkids])
    return yngkid == 0 ? sys.ctc.fam + sys.ctc.baby : sys.ctc.fam
end

@inline function _max_ctc_kid(sys::TaxSystem, fam::Fam)
    return fam.nkids == 0 ? 0.0 : fam.nkids * sys.ctc.kid
end

@inline function _max_wtc_amt(sys::TaxSystem, fam::Fam)
    w = sys.wtc
    chcaresub = 0.0
    maxwtc = 0.0

    if fam.nkids == 0
        if fam.couple == 1
            if (fam.ad[1].age >= w.MinAgeNoKids && fam.ad[1].hrs >= w.MinHrsNoKids - tol) ||
               (fam.ad[2].age >= w.MinAgeNoKids && fam.ad[2].hrs >= w.MinHrsNoKids - tol)
                maxwtc = w.CouLP + w.FT
            end
        else
            if fam.ad[1].age >= w.MinAgeNoKids && fam.ad[1].hrs >= w.MinHrsNoKids - tol
                maxwtc = w.Basic + w.FT
            end
        end
    else
        if fam.couple == 1
            if (fam.ad[1].hrs >= w.MinHrsKids - tol || fam.ad[2].hrs >= w.MinHrsKids - tol) &&
               (fam.ad[1].hrs + fam.ad[2].hrs >= w.MinHrsCouKids - tol)
                maxwtc = (fam.ad[1].hrs + fam.ad[2].hrs >= w.FTHrs - tol) ?
                         w.CouLP + w.FT : w.CouLP
            end
        else
            if fam.ad[1].hrs >= w.MinHrsKids - tol
                maxwtc = fam.ad[1].hrs >= w.FTHrs - tol ? w.CouLP + w.FT : w.CouLP
            end
        end
    end

    # Childcare element
    if maxwtc > tol && fam.nkids > 0 && fam.ccexp > tol
        nkidscc = count(i -> fam.kidage[i] <= w.MaxAgeCC, 1:fam.nkids)
        if nkidscc >= 1
            both_work = fam.couple == 0 ? fam.ad[1].hrs >= w.MinHrsKids - tol :
                        (fam.ad[1].hrs >= w.MinHrsKids - tol && fam.ad[2].hrs >= w.MinHrsKids - tol)
            if both_work
                if nkidscc == 1
                    chcaresub = min(fam.ccexp, w.MaxCC1) * w.PropCC
                else
                    chcaresub = min(fam.ccexp, w.MaxCC2) * w.PropCC
                end
            end
        end
        maxwtc += chcaresub
    end

    return maxwtc, chcaresub
end

@inline function _ntc_taper(sys::TaxSystem, fam::Fam, pretaxearn_tu::Float64,
                             maxwtc::Float64, maxctcfam::Float64, maxctckid::Float64)
    n = sys.ntc
    if maxctcfam <= tol && maxwtc <= tol
        return 0.0, 0.0
    end

    thr1 = (maxctcfam > tol && maxwtc <= tol) ? n.thr1hi : n.thr1lo

    wtc_val = max(maxwtc - max(pretaxearn_tu - thr1, 0.0) * n.taper1, 0.0)

    ctc_val = if n.taperCTCInOneGo == 1
        max(maxctckid + maxctcfam -
            max(pretaxearn_tu - thr1 - maxwtc / n.taper1, 0.0) * n.taper1, 0.0)
    else
        ctc_kid = max(maxctckid -
                      max(pretaxearn_tu - thr1 - maxwtc / n.taper1, 0.0) * n.taper1, 0.0)
        thr2 = max((maxwtc + maxctckid) / n.taper1 + thr1, n.thr2)
        ctc_kid + max(maxctcfam - max(pretaxearn_tu - thr2, 0.0) * n.taper2, 0.0)
    end

    if wtc_val + ctc_val < n.MinAmt
        return 0.0, 0.0
    end

    return wtc_val, ctc_val
end

@inline function _famcred(sys::TaxSystem, fam::Fam, posttaxearn_tu::Float64)
    fc_val = 0.0
    chcaresub = 0.0
    matgrant_val = 0.0

    maxfc, chcaresub = _max_fc_amt(sys, fam)

    if maxfc > tol
        fc_disreg = _fc_disreg(sys, fam)
        yngkid = fam.nkids > 0 ? minimum(@view fam.kidage[1:fam.nkids]) : -1

        MatGrInFC = 0.0
        if sys.extra.matgrant == 1 && yngkid == 0
            for i in 1:fam.nkids
                fam.kidage[i] == 0 && (MatGrInFC += sys.chben.MatGrantVal / 52.0)
            end
        end

        fc_val = max(maxfc + MatGrInFC -
                     max(max(posttaxearn_tu - fc_disreg, 0.0) +
                         max(fam.maint - sys.fc.MaintDisreg, 0.0) -
                         sys.fc.thres, 0.0) * sys.fc.taper, 0.0)

        fc_val < sys.fc.MinAmt && (fc_val = 0.0)

        if fc_val > 0.0 && sys.extra.matgrant == 1 && yngkid == 0
            matgrant_val = min(fc_val, MatGrInFC)
            fc_val = max(0.0, fc_val - MatGrInFC)
        end
    end

    return fc_val, chcaresub, matgrant_val
end

@inline function _max_fc_amt(sys::TaxSystem, fam::Fam)
    fc = sys.fc
    chcaresub = 0.0
    fam.nkids == 0 && return 0.0, 0.0

    maxfc = 0.0
    if fam.couple == 1
        if fam.ad[1].hrs >= fc.hours1 - tol || fam.ad[2].hrs >= fc.hours1 - tol
            maxfc = fc.adult
            (fam.ad[1].hrs >= fc.hours2 - tol || fam.ad[2].hrs >= fc.hours2 - tol) && (maxfc += fc.ftprem)
        end
    else
        if fam.ad[1].hrs >= fc.hours1 - tol
            maxfc = fc.adult
            fam.ad[1].hrs >= fc.hours2 - tol && (maxfc += fc.ftprem)
        end
    end

    if maxfc > tol
        for i in 1:fam.nkids
            for j in 1:fc.NumAgeRng
                if fam.kidage[i] >= fc.kidagel[j] && fam.kidage[i] <= fc.kidageu[j]
                    maxfc += fc.kidcred[j]
                    break
                end
            end
        end

        if fam.ccexp > tol && fc.WFTCMaxCC1 > tol
            nkidscc = count(i -> fam.kidage[i] <= fc.WFTCMaxAgeCC, 1:fam.nkids)
            if nkidscc >= 1
                both_work = fam.couple == 0 ||
                    (fam.ad[1].hrs >= fc.hours1 - tol && fam.ad[2].hrs >= fc.hours1 - tol)
                if both_work
                    cap = nkidscc == 1 ? fc.WFTCMaxCC1 : fc.WFTCMaxCC2
                    chcaresub = min(fam.ccexp, cap) * fc.WFTCPropCC
                end
            end
            maxfc += chcaresub
        end
    end

    return maxfc, chcaresub
end

@inline function _fc_disreg(sys::TaxSystem, fam::Fam)
    fc = sys.fc
    fc.MaxCC1 <= tol && return 0.0
    fam.nkids == 0 && return 0.0
    fam.ccexp <= tol && return 0.0

    elig = false
    if fam.couple == 1
        fam.ad[1].hrs >= fc.hours1 - tol && fam.ad[2].hrs >= fc.hours1 - tol && (elig = true)
    else
        fam.ad[1].hrs >= fc.hours1 - tol && (elig = true)
    end

    nkidscc = count(i -> fam.kidage[i] < fc.MaxAgeCC, 1:fam.nkids)
    if elig && nkidscc > 0
        if nkidscc == 1
            return min(fam.ccexp, fc.MaxCC1)
        else
            return fc.MaxCC2 > tol ? min(fam.ccexp, fc.MaxCC2) : min(fam.ccexp, fc.MaxCC1)
        end
    end
    return 0.0
end

# ──────────────────────────────────────────────────────────────────────
# CHILD BENEFIT
# ──────────────────────────────────────────────────────────────────────

@inline function _chben(sys::TaxSystem, fam::Fam, inctax1::Float64, inctax2::Float64,
                         posttaxearn1::Float64, posttaxearn2::Float64, posttaxearn_tu::Float64)
    fam.nkids == 0 && return 0.0, inctax1, inctax2, posttaxearn1, posttaxearn2, posttaxearn_tu

    cb = sys.chben
    chben_val = cb.basic * fam.nkids + cb.kid1xtr
    fam.couple == 0 && (chben_val += cb.opf)

    chben_tol = 1.0e-8

    if cb.doTaper == 1
        pe = fam.couple == 0 ? 1 : (fam.ad[1].earn >= fam.ad[2].earn ? 1 : 2)
        pe_earn = fam.ad[pe].earn

        if cb.disableTaperRounding == 0
            excessAnnEarn = max(0.0, Float64(floor((pe_earn - cb.taperStart) * 52.0 + chben_tol)))
            percentLost = Float64(floor(excessAnnEarn * cb.taperRate + tol) / 100.0)
            chBenCharge = min(Float64(floor(chben_val * 52.0 * percentLost)) / 52.0, chben_val)
        else
            excessAnnEarn = max(0.0, (pe_earn - cb.taperStart) * 52.0)
            percentLost = (excessAnnEarn * cb.taperRate) / 100.0
            chBenCharge = min(chben_val * percentLost, chben_val)
        end

        if cb.taperIsIncTax == 1
            if pe == 1
                inctax1 += chBenCharge
                posttaxearn1 -= chBenCharge
            else
                inctax2 += chBenCharge
                posttaxearn2 -= chBenCharge
            end
            posttaxearn_tu -= chBenCharge
        else
            chben_val -= chBenCharge
        end
    end

    return chben_val, inctax1, inctax2, posttaxearn1, posttaxearn2, posttaxearn_tu
end

# ──────────────────────────────────────────────────────────────────────
# MATERNITY GRANT
# ──────────────────────────────────────────────────────────────────────

@inline function _matgrant(sys::TaxSystem, fam::Fam, incsup::Float64, fc::Float64, ctc::Float64)
    matgrant = 0.0
    fam.nkids == 0 && return matgrant
    dogrant = false

    if incsup > tol
        dogrant = true
    elseif sys.rebatesys.RulesUnderFC == 1 || sys.rebatesys.RulesUnderWFTC == 1
        fc > tol && (dogrant = true)
    elseif sys.rebatesys.RulesUnderNTC == 1
        ctc > _max_ctc_fam(sys, fam) + tol && (dogrant = true)
    end

    if sys.chben.MatGrantOnlyFirstKid == 1
        for i in 1:fam.nkids
            fam.kidage[i] > 0 && fam.kidage[i] < 16 && (dogrant = false)
        end
    end

    if dogrant
        for i in 1:fam.nkids
            fam.kidage[i] == 0 && (matgrant += sys.chben.MatGrantVal / 52.0)
        end
    end
    return matgrant
end

# ──────────────────────────────────────────────────────────────────────
# FREE SCHOOL MEALS
# ──────────────────────────────────────────────────────────────────────

@inline function _fsm(sys::TaxSystem, fam::Fam, incsup::Float64, ctc::Float64,
                       wtc::Float64, pretaxearn_tu::Float64)
    fsm = 0.0
    if ((incsup > tol) || (ctc > tol && wtc <= tol &&
            pretaxearn_tu <= sys.ntc.thr1hi + tol)) && sys.extra.fsminappamt == 0
        for i in 1:fam.nkids
            fam.kidage[i] > 4 && (fsm += sys.incsup.ValFSM)
        end
    end
    return fsm
end

# ──────────────────────────────────────────────────────────────────────
# UNIVERSAL CREDIT
# ──────────────────────────────────────────────────────────────────────

@inline function _uc_std_allow(sys::TaxSystem, fam::Fam)
    uc = sys.uc
    if fam.couple == 0
        return fam.ad[1].age < uc.MinAgeMain ? uc.YngSin : uc.MainSin
    else
        return (fam.ad[1].age < uc.MinAgeMain && fam.ad[2].age < uc.MinAgeMain) ?
               uc.YngCou : uc.MainCou
    end
end

@inline function _uc_kid(sys::TaxSystem, fam::Fam)
    fam.nkids == 0 && return 0.0
    return sys.uc.FirstKid + (fam.nkids - 1) * sys.uc.OtherKid
end

@inline function _uc_chcare(sys::TaxSystem, fam::Fam)
    uc = sys.uc
    fam.nkids == 0 && return 0.0
    fam.ccexp <= tol && return 0.0

    nkidscc = count(i -> fam.kidage[i] <= uc.MaxAgeCC, 1:fam.nkids)
    nkidscc == 0 && return 0.0

    both_work = fam.couple == 0 ? fam.ad[1].hrs > tol :
                (fam.ad[1].hrs > tol && fam.ad[2].hrs > tol)
    !both_work && return 0.0

    cap = nkidscc == 1 ? uc.MaxCC1 : uc.MaxCC2
    return min(fam.ccexp, cap) * uc.PropCC
end

@inline function _uc_housing(sys::TaxSystem, fam::Fam)
    h = fam.rent
    sys.uc.doRentCap == 1 && (h = min(fam.rent, fam.rentcap))
    return h
end

@inline function _uc_disreg(sys::TaxSystem, fam::Fam, uc_housing::Float64)
    uc = sys.uc
    if fam.couple == 1
        if fam.nkids > 0
            return uc_housing > tol ? uc.DisregCouKidsLo : uc.DisregCouKidsHi
        else
            return uc_housing > tol ? uc.DisregCouNoKidsLo : uc.DisregCouNoKidsHi
        end
    else
        if fam.nkids > 0
            return uc_housing > tol ? uc.DisregSinKidsLo : uc.DisregSinKidsHi
        else
            return uc_housing > tol ? uc.DisregSinNoKidsLo : uc.DisregSinNoKidsHi
        end
    end
end

@inline function _univcred(sys::TaxSystem, fam::Fam, posttaxearn_tu::Float64)
    uc_housing_val = _uc_housing(sys, fam)
    uc_chcare_val = _uc_chcare(sys, fam)
    maxuc = _uc_std_allow(sys, fam) + _uc_kid(sys, fam) + uc_chcare_val + uc_housing_val
    uc_disreg_val = _uc_disreg(sys, fam, uc_housing_val)

    uc_val = max(maxuc - max(posttaxearn_tu - uc_disreg_val, 0.0) * sys.uc.taper, 0.0)
    uc_val < sys.uc.MinAmt && (uc_val = 0.0)

    return uc_val, maxuc, uc_chcare_val
end

# ──────────────────────────────────────────────────────────────────────
# BENEFIT CAP
# ──────────────────────────────────────────────────────────────────────

@inline function _bencap_level(sys::TaxSystem, fam::Fam)
    bc = sys.bencap
    if fam.couple == 1
        return fam.nkids > 0 ? bc.couKids : bc.couNoKids
    else
        return fam.nkids > 0 ? bc.sinKids : bc.sinNoKids
    end
end

@inline function _impose_bencap(sys::TaxSystem, fam::Fam,
                                 uc::Float64, hben::Float64, chben::Float64,
                                 ctc::Float64, incsup::Float64, wtc::Float64,
                                 posttaxearn_tu::Float64)
    bc = sys.bencap
    uc_out = uc
    hben_out = hben

    if bc.doThruUC == 1
        if uc > tol && posttaxearn_tu + tol < bc.UCEarnThr
            preCap = max(0.0, uc - _uc_chcare(sys, fam)) + chben
            excess = max(0.0, preCap - _bencap_level(sys, fam))
            uc_out = max(0.0, uc - excess)
        end
    else
        maxage = fam.ad[1].age
        fam.couple == 1 && (maxage = max(maxage, fam.ad[2].age))
        if hben > tol && wtc < tol && maxage < sys.statepen.PenAgeWoman
            preCap = incsup + hben + chben + ctc
            excess = max(0.0, preCap - _bencap_level(sys, fam))
            hben_out = max(sys.hben.MinAmt, hben - excess)
        end
    end

    return uc_out, hben_out
end

# ──────────────────────────────────────────────────────────────────────
# MAIN CALCULATION
# ──────────────────────────────────────────────────────────────────────

"""
    calc_net_inc(sys::TaxSystem, fam::Fam) -> Net

Calculate net incomes for a family given a tax-benefit system.
This is the main entry point, equivalent to Fortran `CalcNetInc`.
All calculation is pure and allocation-free on the hot path.
"""
function calc_net_inc(sys::TaxSystem, fam::Fam)
    # Pre-tax earnings
    pretaxearn1 = fam.ad[1].earn
    pretaxearn2 = fam.ad[2].earn
    pretaxearn_tu = pretaxearn1 + (fam.couple == 1 ? pretaxearn2 : 0.0)

    # 1. NATIONAL INSURANCE
    natins1, natinsc1_1, natinsc2_1, natinsc4_1 = _natins(sys, fam, 1)
    if fam.couple == 1
        natins2, natinsc1_2, natinsc2_2, natinsc4_2 = _natins(sys, fam, 2)
    else
        natins2 = natinsc1_2 = natinsc2_2 = natinsc4_2 = 0.0
    end

    # Build initial NetAd for taxable earnings calculation (need NI for C4 rebate)
    ad1 = NetAd(0.0, 0.0, natins1, natinsc1_1, natinsc2_1, natinsc4_1, pretaxearn1, 0.0)
    ad2 = NetAd(0.0, 0.0, natins2, natinsc1_2, natinsc2_2, natinsc4_2, pretaxearn2, 0.0)

    # 2. INCOME TAX
    ad1, ad2 = _tearn(sys, fam, ad1, ad2)

    inctax1 = _inctax_amount(sys, ad1.taxable)
    inctax2 = fam.couple == 1 ? _inctax_amount(sys, ad2.taxable) : 0.0

    inctax1, inctax2 = _taxafterctc(sys, fam, inctax1, inctax2, ad1.taxable, ad2.taxable)
    inctax1, inctax2 = _taxaftermca(sys, fam, inctax1, inctax2)

    posttaxearn1 = fam.ad[1].earn - inctax1 - natins1
    posttaxearn2 = fam.couple == 1 ? fam.ad[2].earn - inctax2 - natins2 : 0.0
    posttaxearn_tu = posttaxearn1 + posttaxearn2

    # 3. CHILD BENEFIT
    chben_val = 0.0
    if sys.chben.doChBen == 1
        chben_val, inctax1, inctax2, posttaxearn1, posttaxearn2, posttaxearn_tu =
            _chben(sys, fam, inctax1, inctax2, posttaxearn1, posttaxearn2, posttaxearn_tu)
    end

    # 4. TAX CREDITS
    wtc_val = 0.0
    ctc_val = 0.0
    fc_val = 0.0
    chcaresub = 0.0
    matgrant_val = 0.0

    if sys.fc.dofamcred == 1
        fc_val, chcaresub, matgrant_val = _famcred(sys, fam, posttaxearn_tu)
    end

    if sys.ntc.donewtaxcred == 1
        maxwtc, chcaresub_ntc = _max_wtc_amt(sys, fam)
        chcaresub = chcaresub_ntc  # NTC childcare overrides FC
        wtc_val, ctc_val = _ntc_taper(sys, fam, pretaxearn_tu, maxwtc,
                                      _max_ctc_fam(sys, fam), _max_ctc_kid(sys, fam))
    end

    # 5. UNIVERSAL CREDIT
    uc_val = 0.0
    maxuc = 0.0
    if sys.uc.doUnivCred == 1
        uc_val, maxuc, uc_chcaresub = _univcred(sys, fam, posttaxearn_tu)
        chcaresub = uc_chcaresub
    end

    # 6. IS AND IB-JSA
    incsup_val = 0.0
    if sys.incsup.doIncSup == 1
        incsup_val, matgrant_val = _incsup(sys, fam, posttaxearn_tu, posttaxearn1, posttaxearn2,
                                           chben_val, fc_val, wtc_val, matgrant_val)
    end

    # Maternity grant (if not handled through IS/FC)
    if sys.extra.matgrant == 0
        matgrant_val = _matgrant(sys, fam, incsup_val, fc_val, ctc_val)
    end

    # Free school meals
    fsm_val = _fsm(sys, fam, incsup_val, ctc_val, wtc_val, pretaxearn_tu)

    # 7. HB, CTB AND CCB
    # Preliminary calculations
    disregRebate = 0.0
    if incsup_val <= tol
        appamt = _hb_appamt(sys, fam, maxuc)
        if sys.rebatesys.RulesUnderUC == 0
            disregStd = _std_disreg(sys, fam)
            disregFT = _ft_disreg(sys, fam, fc_val)
            disregCC = _chcare_disreg(sys, fam)
            disregMnt = _maint_disreg(sys, fam)
        else
            disregStd = disregFT = disregCC = disregMnt = 0.0
        end
        disregRebate = _rebate_disreg(sys, fam, posttaxearn_tu, fc_val, wtc_val,
                                      ctc_val, uc_val, chben_val, appamt,
                                      disregStd, disregFT, disregCC, disregMnt)
    end

    # Housing benefit
    hben_val = sys.hben.doHBen == 1 ? _hben(sys, fam, incsup_val, disregRebate) : 0.0

    # Poll tax
    polltax_val = 0.0
    polltaxben_val = 0.0
    if sys.ccben.dopolltax == 1
        polltax_val = _polltax(sys, fam)
        polltaxben_val = _polltaxben(sys, fam, polltax_val, incsup_val, disregRebate)
    end

    # Council tax
    ctax_val = sys.ctax.docounciltax == 1 ? _ctax(sys, fam) : 0.0

    # Council tax benefit
    ctaxben_val = sys.ctaxben.docounciltaxben == 1 ?
                  _ctaxben(sys, fam, ctax_val, incsup_val, disregRebate) : 0.0

    # Benefit cap
    if sys.bencap.doCap == 1
        uc_val, hben_val = _impose_bencap(sys, fam, uc_val, hben_val, chben_val,
                                          ctc_val, incsup_val, wtc_val, posttaxearn_tu)
    end

    # Disposable income
    totben = chben_val + matgrant_val + fc_val + wtc_val + ctc_val +
             incsup_val + fsm_val + hben_val + ctaxben_val + polltaxben_val + uc_val

    nettax = inctax1 + natinsc1_1 + natinsc2_1 + natinsc4_1 +
             ctax_val + polltax_val - totben
    if fam.couple == 1
        nettax += inctax2 + natinsc1_2 + natinsc2_2 + natinsc4_2
    end

    pretax = fam.ad[1].earn + fam.maint
    fam.couple == 1 && (pretax += fam.ad[2].earn)

    dispinc = pretax - nettax

    # Build result
    final_ad1 = NetAd(ad1.taxable, inctax1, natins1, natinsc1_1, natinsc2_1, natinsc4_1,
                      pretaxearn1, posttaxearn1)
    final_ad2 = NetAd(ad2.taxable, inctax2, natins2, natinsc1_2, natinsc2_2, natinsc4_2,
                      pretaxearn2, posttaxearn2)
    tu = NetTU(pretaxearn_tu, posttaxearn_tu, chben_val, matgrant_val,
               fc_val, wtc_val, ctc_val, fam.ccexp, incsup_val, hben_val,
               polltax_val, polltaxben_val, ctax_val, ctaxben_val, maxuc, uc_val,
               dispinc, pretax, nettax, chcaresub, fsm_val, totben)

    return Net(SVector(final_ad1, final_ad2), tu)
end

end # module FortaxCalc
