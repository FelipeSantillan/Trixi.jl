using OrdinaryDiffEq
using Trixi

###############################################################################
# semidiscretization of the compressible Euler multicomponent equations

# 1) Dry Air  2) Helium + 28% Air  3) Carbon Dioxide
equations           = CompressibleEulerMulticomponentEquations2D(gammas        = (1.4, 1.648, 1.28), 
                                                                 gas_constants = (0.287, 1.578, 0.1889))

initial_condition   = initial_condition_shock_bubble

surface_flux        = flux_lax_friedrichs
volume_flux         = flux_chandrashekar
basis               = LobattoLegendreBasis(3)
indicator_sc        = IndicatorHennemannGassner(equations, basis,
                                                alpha_max=0.3,
                                                alpha_min=0.001,
                                                alpha_smooth=true,
                                                variable=density_pressure)
volume_integral     = VolumeIntegralShockCapturingHG(indicator_sc;
                                                     volume_flux_dg=volume_flux,
                                                     volume_flux_fv=surface_flux)
solver              = DGSEM(basis, surface_flux, volume_integral)

coordinates_min     = (-3.0, -3.0)
coordinates_max     = ( 3.0,  3.0)
mesh                = TreeMesh(coordinates_min, coordinates_max,
                               initial_refinement_level=3,
                               n_cells_max=1_000_000)

semi                = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver)


###############################################################################
# ODE solvers, callbacks etc.

tspan               = (0.0, 0.015) 
ode                 = semidiscretize(semi, tspan)

summary_callback    = SummaryCallback()

analysis_interval   = 200 # change to 200+ for whole calc.
analysis_callback   = AnalysisCallback(semi, interval=analysis_interval,
                                       extra_analysis_integrals=(Trixi.density,))

alive_callback      = AliveCallback(analysis_interval=analysis_interval)

save_solution       = SaveSolutionCallback(interval=200,     # 40 or change to 200+ for whole calc.  
                                           save_initial_solution=true,
                                           save_final_solution=true,
                                           solution_variables=cons2prim)

stepsize_callback   = StepsizeCallback(cfl=0.3)

callbacks           = CallbackSet(summary_callback,
                                  analysis_callback, 
                                  alive_callback, 
                                  save_solution,
                                  stepsize_callback)


###############################################################################
# run the simulation
sol                 = solve(ode, CarpenterKennedy2N54(williamson_condition=false),
                                                      dt=1.0, # solve needs some value here but it will be overwritten by the stepsize_callback
                                                      save_everystep=false, 
                                                      callback=callbacks, 
                                                      maxiters=1e5);
summary_callback() # print the timer summary