using Test
using StaticArrays
using Fortax

@testset "Fortax.jl" begin

    @testset "Read system" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        @test sys.inctax.numbands > 0
        @test sys.inctax.pa > 0.0
        @test sys.natins.numrates > 0
        @test sys.chben.basic > 0.0
        @test sys.chben.doChBen == 1
        @test sys.hben.doHBen == 1
    end

    @testset "Load price index" begin
        rpi = load_index(joinpath(@__DIR__, "..", "res", "prices", "rpi.csv"))
        @test rpi.ndate > 0
        @test rpi.date[1] > 0
        @test rpi.index[1] > 0.0
    end

    @testset "Load system index" begin
        si = load_sysindex(joinpath(@__DIR__, "..", "res", "systems", "sysindex.csv"))
        @test si.nsys > 0
        @test length(si.fname) > 0
    end

    @testset "Price index lookup" begin
        rpi = load_index(joinpath(@__DIR__, "..", "res", "prices", "rpi.csv"))
        # The index should have a value for a known date
        idx = get_index(rpi, rpi.date[1])
        @test idx ≈ rpi.index[1]
    end

    @testset "Uprate factor" begin
        rpi = load_index(joinpath(@__DIR__, "..", "res", "prices", "rpi.csv"))
        # Uprating from a date to itself should give factor 1.0
        f = uprate_factor(rpi, rpi.date[1], rpi.date[1])
        @test f ≈ 1.0
    end

    @testset "Single adult, no children" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        ad1 = FamAd(age=30, selfemp=0, hrs=37.5, earn=500.0)
        fam = Fam(ad = SVector(ad1, FamAd()))
        net = calc_net_inc(sys, fam)

        @test net.ad[1].pretaxearn ≈ 500.0
        @test net.ad[1].inctax >= 0.0
        @test net.ad[1].natins >= 0.0
        @test net.ad[1].posttaxearn ≈ 500.0 - net.ad[1].inctax - net.ad[1].natins
        @test net.tu.dispinc > 0.0
        @test net.tu.chben ≈ 0.0
        @test net.tu.incsup ≈ 0.0
    end

    @testset "Single parent with children" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        ad1 = FamAd(age=30, selfemp=0, hrs=20.0, earn=150.0)
        fam = Fam(
            ad = SVector(ad1, FamAd()),
            kidage = (3, 7)
        )
        net = calc_net_inc(sys, fam)

        @test net.tu.chben > 0.0
        @test net.tu.dispinc > 0.0
        # Low-income lone parent should get benefits
        @test net.tu.totben > 0.0
    end

    @testset "Couple with children" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        ad1 = FamAd(age=35, selfemp=0, hrs=37.5, earn=400.0)
        ad2 = FamAd(age=33, selfemp=0, hrs=20.0, earn=150.0)
        fam = Fam(
            couple = 1,
            married = 1,
            ad = SVector(ad1, ad2),
            kidage = (5,)
        )
        net = calc_net_inc(sys, fam)

        @test net.ad[1].pretaxearn ≈ 400.0
        @test net.ad[2].pretaxearn ≈ 150.0
        @test net.tu.chben > 0.0
        @test net.tu.dispinc > 0.0
    end

    @testset "Zero earnings → IS eligible" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        ad1 = FamAd(age=30, selfemp=0, hrs=0.0, earn=0.0)
        fam = Fam(
            ad = SVector(ad1, FamAd()),
            kidage = (5,)
        )
        net = calc_net_inc(sys, fam)

        @test net.tu.incsup > 0.0  # Should receive income support
        @test net.tu.chben > 0.0
        @test net.ad[1].inctax ≈ 0.0
        @test net.ad[1].natins ≈ 0.0
    end

    @testset "Self-employed NI" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        ad1 = FamAd(age=40, selfemp=1, hrs=40.0, earn=500.0)
        fam = Fam(ad = SVector(ad1, FamAd()))
        net = calc_net_inc(sys, fam)

        @test net.ad[1].natinsc1 ≈ 0.0  # No Class 1 for self-employed
        # Should have Class 2 and/or Class 4
        @test net.ad[1].natins > 0.0
    end

    @testset "System uprating" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        sys2 = uprate_sys(sys, 1.05)

        @test sys2.inctax.pa ≈ sys.inctax.pa * 1.05
        @test sys2.chben.basic ≈ sys.chben.basic * 1.05
        # Rates should not change
        @test sys2.inctax.rates == sys.inctax.rates
        @test sys2.hben.taper ≈ sys.hben.taper
    end

    @testset "Extra utilities" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))

        # set_min_amount
        sys2 = set_min_amount(sys, 0.50)
        @test sys2.fc.MinAmt ≈ 0.50
        @test sys2.hben.MinAmt ≈ 0.50

        # disable_taper_rounding
        sys3 = disable_taper_rounding(sys)
        @test sys3.chben.disableTaperRounding == 1
        @test sys3.inctax.disablePATaperRounding == 1
    end

    @testset "Impose UC" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        sys_uc = impose_uc(sys)

        @test sys_uc.uc.doUnivCred == 1
        @test sys_uc.incsup.doIncSup == 0
        @test sys_uc.hben.doHBen == 0
        @test sys_uc.fc.dofamcred == 0
        @test sys_uc.ntc.donewtaxcred == 0
        @test sys_uc.rebatesys.RulesUnderUC == 1
    end

    @testset "Budget constraint (kinks)" begin
        sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "April10.json"))
        ad1 = FamAd(age=30, selfemp=0, hrs=0.0, earn=0.0)
        fam = Fam(
            ad = SVector(ad1, FamAd()),
            kidage = (5,)
        )

        bc = kinks_earn(sys, fam, 1, 37.5, 0.0, 1000.0)
        @test bc.kinks_num > 1
        @test bc.kinks_earn[1] ≈ 0.0
    end

    @testset "Multiple system years" begin
        # Verify we can load and calc for multiple years
        for year in ["April00", "April05", "April10", "April15"]
            sys = read_system(joinpath(@__DIR__, "..", "res", "systems", "fortax", "$year.json"))
            ad1 = FamAd(age=30, selfemp=0, hrs=37.5, earn=400.0)
            fam = Fam(ad = SVector(ad1, FamAd()))
            net = calc_net_inc(sys, fam)
            @test net.tu.dispinc > 0.0
        end
    end

end
