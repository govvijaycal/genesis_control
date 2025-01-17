#!/usr/bin/env julia

#=
 This is a modified version of controller_MPC_traj.jl from the barc project ROS codebase.
 Modified by Vijay Govindarajan.

 Licensing Information: You are free to use or extend these projects for 
 education or research purposes provided that (1) you retain this notice
 and (2) you provide clear attribution to UC Berkeley, including a link 
 to http://barc-project.com

 Attibution Information: The barc project ROS code-base was developed
 at UC Berkeley in the Model Predictive Control (MPC) lab by Jon Gonzales
 (jon.gonzales@berkeley.edu). The cloud services integation with ROS was developed
 by Kiet Lam  (kiet.lam@berkeley.edu). The web-server app Dator was 
 based on an open source project by Bruce Wootton
=# 

#=
	Frenet Pathfollowing that uses linear approximation
		- this module is concerned with Longitudinal control
		- tracks (s_ref, v_ref)
		- NOTE: BOX constraint on "s" (using largeNumber) is not well-implemented atm
=#



module GPSKinMPCPathFollowerFrenetLinLongGurobi
	__precompile__()

	using Gurobi
	# using Mosek
	# using Ipopt
    # using MathProgBase 
    # using OSQP 	# https://github.com/JuliaOpt/Gurobi.jl
    # using ECOS

	println("Creating longitudinal kinematic bicycle model in Gurobi/OSQP ....")

 
	# ====================== general problem formulation is given by ======================
	# x_{k+1} = A x_k + B u_k + g_k
	# u_lb <= u_k <= u_ub
	# x_lb <= x_k <= x_ub
	# dU_lb <= u_k - u_{k-1} <= dU_ub
	# minimize (x_k - x_k_ref)' * Q * (x_k - x_k_ref) + (u_k - u_k_ref)' * R * (u_k - u_k_ref) + (u_k - u_{k-1})' * Rdelta * (u_k - u_{k-1}) 


	# general control parameters
	# some might be passed on as arguments
	# dt      = 0.20			# model discretization time, td (s)
	dt 		= 0.1
	# N       = 8				# horizon
	N		= 16
	nx 		= 2				# dimension of x = (s,v)
	nu 		= 1				# number of inputs u = a
	# L_a     = 1.108 		# dist from CoG to front axle (m)
	L_a 	= 1.5213		# from CoG to front axle (according to Jongsang)
	# L_b     = 1.742 		# dist from CoG to rear axle (m)
	L_b 	= 1.4987		# from CoG to rear axle (according to Jongsang)

	# define System matrices (all time-invariant)
	A = [	1 	dt 		# can be made more exact using matrix exponential
			0	1 	]
	B = [ 	0
			dt 		]
	g = zeros(nx)

	# define cost functions
    C_s = 20			# track progress
	C_v = 100;			# ref velocity tracking weight			
	C_acc = 0
	C_dacc = 11;		# 20 too high; 10 OK for med speed; 10 a big jerky for high speed; 13 too high

	Q = diagm([C_s ; C_v])	# create diagonal matrix
	R = C_acc
	Rdelta = C_dacc

	# define (box) constraints
	largeNumber = 1e5;		# use this number for variables that are not upper/lower bounded
	v_min = 0.0				# vel bounds (m/s)
	v_max = 20.0	
	a_max = 2.0				# acceleration and deceleration bound, m/s^2
	a_dmax = 1.5			# jerk bound, m/s^3

	x_lb = [	-largeNumber	# make sure car doesnt travel more than largeNumber [m]
				v_min		]
	x_ub = [	largeNumber		
				v_max		]

	u_lb = -a_max
	u_ub = a_max

	dU_lb = -a_dmax*dt 	# double check if *dt is needed (or not)
	dU_ub = a_dmax*dt


	# build references (should be passed on as arguments later on)
	# get init x_ref for one initial solve (to speed up Julia)
    s_ref_init   = 1.0*collect(dt:dt:(N)*dt)		# target s(1), ..., s(N)
	v_ref_init = ones(N,1)						# reference velocity 
	x_ref_init = zeros(N*nx,1)
	for i = 1 : N
		x_ref_init[(i-1)*nx+1] = s_ref_init[i]		# set x_ref
		x_ref_init[(i-1)*nx+2] = v_ref_init[i]		# set v_ref
	end

	# input reference
	u_ref_init = zeros(N,1)	# if not used, set cost to zeros


	# get Initial state and input
	# should be done dynamically later on
	s0_init = 0
	v0_init = 0
	x0_init = [s0_init ; v0_init]
	u0_init = 0


	# ================== Transformation 1 ======================
	# augment state and redefine system dynamics (A,B,g) and constraints
	# x_tilde_k := (x_k , u_{k-1})
	# u_tilde_k := (u_k - u_{k-1})

	A_tilde = [	A 				B
				zeros(nu,nx) 	eye(nu)	]

	B_tilde = [	B ; eye(nu)	]

	g_tilde = [	g ;	zeros(nu) ]

	x_tilde_lb = [x_lb ; u_lb]
	x_tilde_ub = [x_ub ; u_ub]
	u_tilde_lb = dU_lb
	u_tilde_ub = dU_ub

	Q_tilde = [	Q 			zeros(nx,nu) 		# may also use cat(?)
				zeros(nu,nx)	R 			]	# actually not needed

	R_tilde = Rdelta

	x_tilde_0_init = [x0_init ; u0_init]	# initial state of system; PARAMETER

	x_tilde_ref_init = zeros(N*(nx+nu))
	for i = 1 : N
		x_tilde_ref_init[(i-1)*(nx+nu)+1 : (i-1)*(nx+nu)+nx] = x_ref_init[(i-1)*nx+1 : i*nx]
		x_tilde_ref_init[(i-1)*(nx+nu)+nx+1 : (i-1)*(nx+nu)+nx+nu] = u_ref_init[i]
	end

	u_tilde_ref_init = zeros(N*nu) 	# goal is to minimize uTilde = (acc_k - acc_{k-1})

	# ================== Transformation 2 ======================
	# bring into GUROBI format
	# minimize_z    z' * H * z + f' * z
	#	s.t.		A_eq * z = b_eq
	#				A * z <= b
	#				z_lb <= z <= z_ub

	# z := (u_tilde_0, x_tilde_1 , u_tilde_1 x_tilde_2 , ... u_tilde_{N-1}, x_tilde_N , )
	
	n_uxu = nu+nx+nu 	# size of one block of (u_tilde, x_tilde) = (deltaU, x, u)

	# Build cost function
	# cost for (u_tilde, x_tilde) = (deltaU , S, V, U)
	H_block = [	R_tilde zeros(nu, nu+nx)
				zeros(nu+nx,nu) Q_tilde		];
	H_gurobi = kron(eye(N), H_block)


	z_gurobi_ref_init = zeros(N*n_uxu) 	# reference point for z_gurobi ; PARAMETER!
	for i = 1 : N
		z_gurobi_ref_init[(i-1)*n_uxu+1 : (i-1)*n_uxu+nu] = u_tilde_ref_init[(i-1)*nu+1 : i*nu] 		# should be zero for this application
		z_gurobi_ref_init[(i-1)*n_uxu+nu+1 : i*n_uxu] = x_tilde_ref_init[(i-1)*(nx+nu)+1 : i*(nu+nx)]
	end 


	f_gurobi_init = -2*H_gurobi*z_gurobi_ref_init


	# build box constraints lb_gurobi <= z <= ub_gurobi
	# recall: z = (u_tilde, x_tilde, ....)
	lb_gurobi = repmat([u_tilde_lb ; x_tilde_lb], N, 1)		# (deltaU, X, U)
	ub_gurobi = repmat([u_tilde_ub ; x_tilde_ub], N, 1)		# (deltaU, X, U)


	# build equality matrix (most MALAKA task ever)
	nu_tilde = nu
	nx_tilde = nu+nx
	# n_uxu = nu_tilde + nx_tilde
	Aeq_gurobi = zeros(N*nx_tilde , N*(nx_tilde+nu_tilde))
	Aeq_gurobi[1:nx_tilde, 1:(nx_tilde+nu_tilde)] = [-B_tilde eye(nx_tilde)] 	# fill out first row associated with x_tilde_1
	for i = 2 : N  	# fill out rows associated to x_tilde_2, ... , x_tilde_N
		Aeq_gurobi[ (i-1)*nx_tilde+1 : i*nx_tilde  , (i-2)*(nu_tilde+nx_tilde)+(nu_tilde)+1 : (i-2)*(nu_tilde+nx_tilde)+nu_tilde+(nx_tilde+nu_tilde+nx_tilde)    ] = [-A_tilde -B_tilde eye(nx_tilde)]
	end

	# right-hand-size of equality constraint
	beq_gurobi = repmat(g_tilde,N,1);
	beq_gurobi[1:nx_tilde] = beq_gurobi[1:nx_tilde] + A_tilde*x_tilde_0_init 	# PARAMETER: depends on x0


	#**************************************
	#editted by Jiakai set up the terminal constriant
	n_ineq = 47  # number of the terminal constraints
	A_inv = 
	[    0   -0.9578   -0.2873
         0   -0.8575   -0.5145
         0   -0.8944   -0.4472
         0   -0.8192   -0.5735
         0   -0.9285   -0.3714
    0.9436    0.3303    0.0236
    0.8714    0.4793    0.1046
    0.9275    0.3710    0.0464
    0.8915    0.4458    0.0802
    0.7194    0.6474    0.2518
    0.9281    0.3712    0.0278
    0.9700    0.2425    0.0146
    0.9806    0.1961         0
    0.9115    0.4102    0.0319
    0.7873    0.5905    0.1772
    0.8296    0.5392    0.1452
    0.7856    0.5892    0.1886
    0.7428    0.6314    0.2228
    0.8085    0.5659    0.1617
    0.8725    0.4799    0.0916
    0.8927    0.4463    0.0625
    0.6752    0.6752    0.2971
    0.8514    0.5108    0.1192
    0.9270    0.3708    0.0556
    0.9106    0.4098    0.0546
    0.9574    0.2872    0.0287
    0.9432    0.3301    0.0377
    0.6983    0.6634    0.2688
    0.8505    0.5103    0.1276
    0.8310    0.5401    0.1330
    0.8909    0.4454    0.0891
    0.9439    0.3304         0
    0.9889    0.1483         0
    0.9578    0.2873         0
    0.7409    0.6298    0.2334
    0.7641    0.6113    0.2063
    0.8530    0.5118    0.1024
    0.9577    0.2873    0.0192
    0.9805    0.1961    0.0098
    0.9285    0.3714         0
    0.9098    0.4094    0.0682
    0.9701    0.2425         0
         0   -0.9806   -0.1961
         0   -0.9950   -0.0995
    0.9950    0.0995         0
   -1.0000         0         0
         0   -1.0000         0]

     b_inv = [0.0862
    0.2701
    0.2012
    0.3441
    0.1393
    0.0578
    0.0769
    0.0589
    0.0686
    0.1590
    0.0645
    0.0514
    0.0520
    0.0743
    0.1132
    0.0950
    0.1182
    0.1402
    0.1035
    0.0750
    0.0714
    0.1938
    0.0834
    0.0603
    0.0640
    0.0536
    0.0556
    0.1721
    0.0872
    0.0914
    0.0713
    0.0720
    0.0502
    0.0623
    0.1465
    0.1287
    0.0836
    0.0536
    0.0505
    0.0854
    0.0639
    0.0558
    0.0441
    0.0149
    0.0498
    0.0500
         0]
	A_gurobi = zeros(n_ineq, N * n_uxu)
	A_gurobi[1:n_ineq, (N-1)*n_uxu + nu + 1: N * n_uxu] = A_inv
	b_gurobi = b_inv
	println(size(A_gurobi))
	println(size(b_gurobi))
	# The steady state we want is:
	z0 = zeros(N*n_uxu,1)
	z0[(N-1)*n_uxu + nu + 1: N*n_uxu,1] = [50 
											0 
											0]
	println(size(squeeze(A_gurobi * z0,2)))
	println(size(b_gurobi + squeeze(A_gurobi * z0,2)))
	println(size(A_gurobi * z0))							
	println(size(z0))

	#**************************************

	# ================ Solve Problem =================== 
    tic()
    GurobiEnv = Gurobi.Env()
	setparam!(GurobiEnv, "Presolve", 0)	# # set presolve to 0 what does it mean?
	setparam!(GurobiEnv, "LogToConsole", 0)	# # set presolve to 0 what does it mean?

	# add A = A_gurobi and b=b_gurobi for inequality constraint
	# note that: (1/2) * z' * H * z + f' * z
    GurobiModel = gurobi_model(GurobiEnv;
    			name = "qp_01",
    			H = 2*H_gurobi,
    			f = f_gurobi_init,	# PARAMETER that depends on x_ref and u_ref
    			Aeq = Aeq_gurobi,
    			beq = squeeze(beq_gurobi,2),	# PARAMETER that depends on x0, u_{-1}	
    			lb = squeeze(lb_gurobi,2),
    			ub = squeeze(ub_gurobi,2)	)
    optimize(GurobiModel)
	solv_time=toq()
	println("1st solv time Gurobi:  $(solv_time*1000) ms")

	# # access results
	# sol = get_solution(GurobiModel)
	# println("soln = $(sol)")

	# objv = get_objval(GurobiModel)
	# println("objv = $(objv)")


	##### OSQP solver
	    
	# tic()
	# OSQPmdl = OSQP.Model() 	# needs SparseMatrixCSC,
	# A_osqp = sparse( [ Aeq_gurobi ; eye(N*n_uxu) ] )
	# lb_osqp = [ squeeze(beq_gurobi,2) ; squeeze(lb_gurobi,2) ]
	# ub_osqp = [ squeeze(beq_gurobi,2) ; squeeze(ub_gurobi,2) ]
	# P_osqp = sparse(2*H_gurobi)
	# OSQP.setup!(OSQPmdl; P=P_osqp, q=f_gurobi_init, A=A_osqp, l=lb_osqp, u=ub_osqp, verbose=0)
	# results_osqp = OSQP.solve!(OSQPmdl)
	# solv_time=toq()
	# println("1st solv time OSQP:  $(solv_time*1000) ms")
	


	# this function is called iteratively
	function solve_gurobi(s_0::Float64, v_0::Float64, u_0::Float64, s_ref::Array{Float64,1}, v_ref::Array{Float64,1})

		tic()


		# build problem
		x0 = [s_0 ; v_0]
		u0 = u_0 				# it's really u_{-1}
		x_tilde_0 = [x0 ; u0]	# initial state of system; PARAMETER

		# update RHS of linear equality constraint
		beq_gurobi_updated = repmat(g_tilde,N,1);
		beq_gurobi_updated[1:nx_tilde] = beq_gurobi_updated[1:nx_tilde] + A_tilde*x_tilde_0 	# PARAMETER: depends on x0
		
		# editted by Byron and Jiakai
		# update the box constraints
		
		#smallNumber = 50

		#x_lb = [	-smallNumber	  # make sure car doesnt travel more than largeNumber [m]
		#		v_min		]
		#x_ub = [	smallNumber		
		#		v_max		]

		#x_tilde_lb = [x_lb ; u_lb]
		#x_tilde_ub = [x_ub ; u_ub]
		
		#lb_gurobi = repmat([u_tilde_lb ; x_tilde_lb], N, 1)
		#ub_gurobi = repmat([u_tilde_ub ; x_tilde_ub], N, 1)

		# editted by Byron and Jiakai
		
		# update reference trajectories
		x_ref = zeros(N*nx,1)
		for i = 1 : N
			x_ref[(i-1)*nx+1] = s_ref[i+1]		# set x_ref, s_ref/v_ref is of dim N+1
			x_ref[(i-1)*nx+2] = v_ref[i+1]		# set v_ref
		end
		# augment state with input for deltaU-formulation
		x_tilde_ref = zeros(N*(nx+nu))
		for i = 1 : N
			x_tilde_ref[(i-1)*(nx+nu)+1 : (i-1)*(nx+nu)+nx] = x_ref[(i-1)*nx+1 : (i-1)*nx+nx]
			x_tilde_ref[(i-1)*(nx+nu)+nx+1 : (i-1)*(nx+nu)+nx+nu] = u_ref_init[i]	# u_ref_init always 0, but no no weights
		end
		u_tilde_ref = zeros(N*nu) 	# want to minimize deltaU = u_k - u_{k-1}

		z_gurobi_ref = zeros(N*n_uxu) 	# reference point for z_gurobi ; PARAMETER!
		for i = 1 : N
			z_gurobi_ref[(i-1)*n_uxu+1 : (i-1)*n_uxu+nu] = u_tilde_ref[(i-1)*nu+1 : i*nu] 		# should be zero for this application
			z_gurobi_ref[(i-1)*n_uxu+nu+1 : i*n_uxu] = x_tilde_ref[(i-1)*(nx+nu)+1 : i*(nu+nx)]
		end 
		f_gurobi_updated = -2*H_gurobi*z_gurobi_ref


		# formulate optimization problem
		GurobiEnv = Gurobi.Env()	# really necessary?
		setparam!(GurobiEnv, "Presolve", -1)		# -1: automatic; no big influence on solution time
		setparam!(GurobiEnv, "LogToConsole", 0)		# set presolve to 0
		# setparam!(GurobiEnv, "TimeLimit",0.025)		# for 20Hz = 50ms
		# Formulate Optimization Problem
   	 	GurobiModel = gurobi_model(GurobiEnv;
    			name = "qp_01",
    			H = 2*H_gurobi,
    			f = f_gurobi_updated,	# need to make it "flat"
    			Aeq = Aeq_gurobi,
    			beq = squeeze(beq_gurobi_updated,2), # need to make it "flat"
    			#A = A_gurobi,
    			#b = b_gurobi + squeeze(A_gurobi * z0,2),
    			lb = squeeze(lb_gurobi,2), # need to make it "flat"
    			ub = squeeze(ub_gurobi,2)	) # need to make it "flat"
	    optimize(GurobiModel)		 		# solve optimization problem
 		solvTimeGurobi1 = toq()
		optimizer_gurobi = get_solution(GurobiModel)
		status = get_status(GurobiModel)


###############################

		# OSQP implementation (no equality constraints)
		# min 1/2 * x' * P * x + q'*x
		# lb <= Ax <= ub
		
		# tic()
		# OSQPmdl = OSQP.Model() 	# needs SparseMatrixCSC,
		# lb_osqp_updated = [ squeeze(beq_gurobi_updated,2) ; squeeze(lb_gurobi,2) ]
		# ub_osqp_updated = [ squeeze(beq_gurobi_updated,2) ; squeeze(ub_gurobi,2) ]
		# OSQP.setup!(OSQPmdl; P=P_osqp, q=f_gurobi_updated, A=A_osqp, l=lb_osqp_updated, u=ub_osqp_updated, verbose=0)
		# # OSQP.update!(OSQPmdl; q=f_gurobi_updated, l=lb_osqp_updated, u=ub_osqp_updated)
		# results_osqp = OSQP.solve!(OSQPmdl)
		# solvTime_osqp = toq()

		# optimizer_gurobi = results_osqp.x
		# solvTimeGurobi1 = solvTime_osqp
		# status = results_osqp.info.status


###############################
		# alternatively, call via MathProgBase interface
		# http://mathprogbasejl.readthedocs.io/en/latest/quadprog.html
		# tic()
		# solution = quadprog(f_gurobi_updated, 2*H_gurobi, [Aeq_gurobi ; -Aeq_gurobi], '<', [squeeze(beq_gurobi_updated,2) ; -squeeze(beq_gurobi_updated,2)], squeeze(lb_gurobi,2), squeeze(ub_gurobi,2), GurobiSolver(Presolve=0, LogToConsole=0) )
		# solution = quadprog(f_gurobi_updated, 2*H_gurobi, [Aeq_gurobi ; -Aeq_gurobi], '<', [squeeze(beq_gurobi_updated,2) ; -squeeze(beq_gurobi_updated,2)], squeeze(lb_gurobi,2), squeeze(ub_gurobi,2), MosekSolver(LOG=0) )
		# solution = quadprog(f_gurobi_updated, 2*H_gurobi, [Aeq_gurobi ; -Aeq_gurobi], '<', [squeeze(beq_gurobi_updated,2) ; -squeeze(beq_gurobi_updated,2)], squeeze(lb_gurobi,2), squeeze(ub_gurobi,2), IpoptSolver(print_level=0) )
		# solvTimeGurobi2 = toq()
		# optimizer_gurobi = solution.sol

		# if solvTime_osqp > 1e-3
		# 	OSQPmdl = OSQP.Model() 	# needs SparseMatrixCSC,
		# 	lb_osqp_updated = [ squeeze(beq_gurobi_updated,2) ; squeeze(lb_gurobi,2) ]
		# 	ub_osqp_updated = [ squeeze(beq_gurobi_updated,2) ; squeeze(ub_gurobi,2) ]
		# 	OSQP.setup!(OSQPmdl; P=P_osqp, q=f_gurobi_updated, A=A_osqp, l=lb_osqp_updated, u=ub_osqp_updated, verbose=0)
		# 	# OSQP.update!(OSQPmdl; q=f_gurobi_updated, l=lb_osqp_updated, u=ub_osqp_updated)
		# 	tic()
		# 	results_osqp = OSQP.solve!(OSQPmdl)
		# 	solvTime_osqp1 = toq()
		# 	# pure solvTime very low; well under 5ms
		# 	# setup time can cause lots of trouble
		# 	println("*** old osqp pure solv time: $(solvTime_osqp) ***")		# 65ms (setup time)
		# 	println("*** new osqp pure solv time: $(solvTime_osqp1) ***")		# 0.4ms (setup time)
		# end

		# structure of z = [ (dAcc,s,v,Acc) ; (dAcc, s, v, Acc) ; ... ]
		a_pred_gurobi = optimizer_gurobi[4:n_uxu:end]
		s_pred_gurobi = [ s_0 ; optimizer_gurobi[2:n_uxu:end] ] 	# include current s 
		v_pred_gurobi = [ v_0 ; optimizer_gurobi[3:n_uxu:end] ]		# include current v 

		# println("deltaA_gurobi: $(optimizer_gurobi[1:n_uxu:end]')")
		# println("s_pred_gurobi (incl s0): $(s_pred_gurobi)")
		# println("v_pred_gurobi (incl v0): $(v_pred_gurobi)")
		# println("a_pred_gurobi: $(a_pred_gurobi)")
		# println("a0_opt_gurobi: $(optimizer_gurobi[4])")

		acc_opt = optimizer_gurobi[4]

   	 	return acc_opt, a_pred_gurobi, s_pred_gurobi, v_pred_gurobi,  solvTimeGurobi1, status

	end  	# end of solve_gurobi()

end # end of module
