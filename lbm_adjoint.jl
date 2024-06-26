module ALBM

using Plots
using CoherentNoise
using .Threads
using Printf

const c = [  0   0; 
             1   0;
             0   1;
            -1   0; 
             0  -1; 
             1   1; 
            -1   1; 
            -1  -1; 
             1  -1]

const w = [4 / 9, 1 / 9, 1 / 9, 1 / 9, 1 / 9, 1 / 36, 1 / 36, 1 / 36, 1 / 36]

const resolution = 256
const dx = 1 / resolution
const dt = dx

const output_interval = 249


# Equation 32
const alpha_min = 0.0
const alpha_max = 4e2
const ramp_alpha = 0.1

const beta_min = 0.0
const beta_max = 0.1
const ramp_beta = 0.1

const t_end = 100.0
# const n_t = Int(t_end / dt)
const n_t = 500


# Equation 68, 69
const epsilon_u = 1e-4
const epsilon_q = 1e-4

const L_x = 1
const L_y = 2

const n_x = L_x * resolution
const n_y = L_y * resolution

const u_0 = 0.00
const v_0 = 0.1

# Page 369
const rho_0 = 1.0

const g_x = 0.0
const g_y = 0.0

const tau_f = 0.8

const Pr = 6
const nu = (1.0 / 3.0) * (tau_f - 0.5) * dx
const alpha_t =  nu / Pr

const inlet_width = 0.33

const T_0 = 0.0
const T_in = 0.0

const epsilon_test_ap = 1e-4

function pow(x,y)
    return x^y
end

# Equation 5
function f_equilibrium!(f_eq, rho, u, v)
    for i in 1:9
        cu = c[i, 1] * u + c[i, 2] * v
        f_eq[i] = w[i] * rho * (1 + 3 * cu + 9 / 2 * cu^2 - 3 / 2 * (u^2 + v^2))
    end
end

# Equation 6
function g_equilibrium!(g_eq, T, u, v)
	for i in 1:9
		cu = c[i, 1] * u + c[i, 2] * v
		g_eq[i] = w[i] * T * (1 + 3 * cu)
	end
end

# Equation 22, 23
function init_pops!(f, g, rho, u, v, T)
    f_eqs = [zeros(Float32, 9) for i in 1:Threads.nthreads()]
    g_eqs = [zeros(Float32, 9) for i in 1:Threads.nthreads()]

    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            f_equilibrium!(f_eqs[Threads.threadid()], rho[ix, iy], u[ix, iy], v[ix, iy]) # 99% sure this works
            g_equilibrium!(g_eqs[Threads.threadid()], T[ix, iy], u[ix, iy], v[ix, iy])

            f[:,ix,iy] .= f_eqs[Threads.threadid()]
            g[:,ix,iy] .= g_eqs[Threads.threadid()]
        end
    end
end

# Equation 3, 4
function relax!(f, g, p, rho, u, v, T, tau_f, tau_g)
    f_eq_thread_local = [zeros(Float32, 9) for i in 1:Threads.nthreads()]
    g_eq_thread_local = [zeros(Float32, 9) for i in 1:Threads.nthreads()]

    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y

            ti = Threads.threadid()
            
            f_equilibrium!(f_eq_thread_local[ti], rho[ix,iy], u[ix,iy], v[ix,iy])
            g_equilibrium!(g_eq_thread_local[ti], T[ix,iy], u[ix,iy], v[ix,iy])

            for i in 1:9
                f[i,ix,iy] = f[i,ix,iy] - 1/tau_f * (f[i,ix,iy] - f_eq_thread_local[ti][i])
                g[i,ix,iy] = g[i,ix,iy] - 1/tau_g * (g[i,ix,iy] - g_eq_thread_local[ti][i])
            end
        end
    end
end

# Equation 20, 21
function force!(f, g, F, Q_t)
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            for i in 1:9
                f[i,ix,iy] = f[i,ix,iy] + 3.0 * dx*w[i]*(c[i,1]*F[1,ix,iy] + c[i,2]*F[2,ix,iy])
                g[i,ix,iy] = g[i,ix,iy] + dx * w[i]*Q_t[ix,iy] 
            end
        end
    end
end

# equation 8, 9, 10, 11, 12
function compute_moments!(rho, u, v, p, q_t, T, f, g)
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            rho[ix, iy] = 0
            u[ix, iy] = 0
            v[ix, iy] = 0
            p[ix, iy] = 0
            q_t[:, ix, iy] .= 0
            T[ix, iy] = 0

            for i in 1:9
                rho[ix, iy] += f[i, ix, iy]
                u[ix, iy] += c[i, 1] * f[i, ix, iy]
                v[ix, iy] += c[i, 2] * f[i, ix, iy]
                
                T[ix, iy] += g[i, ix, iy]
            end
            
            # Equation 11
            for i in 1:9
                q_t[1, ix, iy] = c[i, 1] * g[i, ix, iy] - T[ix, iy] * u[ix, iy]
                q_t[2, ix, iy] = c[i, 2] * g[i, ix, iy] - T[ix, iy] * v[ix, iy]
            end
            p[ix,iy] = rho[ix,iy] / 3.0
            u[ix, iy] /= rho[ix, iy]
            v[ix, iy] /= rho[ix, iy] 
        end
    end
end

# Equation 32
function compute_alpha_gamma(gamma)
    return @. alpha_max + (alpha_min - alpha_max) * ( gamma * (1 + ramp_alpha)) / (gamma + ramp_alpha)
end

# Equation 36
function compute_beta_gamma(gamma)
    return @. beta_max + (beta_min - beta_max) * ( gamma * (1 + ramp_beta)) / (gamma + ramp_beta)
end


# Equation 16
function compute_tau_f()
    return 3 * nu / dx + 0.5
end


function compute_K_gamma(gamma)
    return @. K_f + (K_s - K_f) * ramp_k  * ( gamma * (1 + ramp_k)) / (gamma + ramp_k)
end

function compute_tau_g()
    # Equation 17
    return 3 * alpha_t / dx + 0.5
    # return @. 3 * K_gamma / dx + 0.5
end

# Equation 31
function compute_F!(F, u, v, alpha_gamma)
    F[1, :, :] .= - alpha_gamma .* u .+ g_x
    F[2, :, :] .= - alpha_gamma .* v .+ g_y
end

# Equation 35
function compute_Q_t!(Q_t, T, beta_gamma)
    Q_t .= beta_gamma .* (1 .- T)
end

function advect_f!(f)
    f_new = zero(f) 

    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            for i in 1:9
                ix_new = ix - c[i, 1]
                iy_new = iy - c[i, 2]

                if ix_new < 1 || ix_new > n_x || iy_new < 1 || iy_new > n_y
                    f_new[i, ix, iy] = 0.0
                else
                    f_new[i, ix, iy] = f[i, ix_new, iy_new]
                end
            end
        end
    end

    ## Boundary Conditions

    x_0 = Int(floor((0.5 - 0.5 * inlet_width) * n_x))
    x_1 = Int(floor((0.5 + 0.5 * inlet_width) * n_x))

    # Bounce Back Left 
    ix = 1
    Threads.@threads for iy in 1:n_y
        f_new[6,ix,iy] = f[8,ix,iy]
        f_new[2,ix,iy] = f[4,ix,iy]
        f_new[9,ix,iy] = f[7,ix,iy]
    end

    # Bounce Back Right
    ix = n_x
    Threads.@threads for iy in 1:n_y
        f_new[8,ix,iy] = f[6,ix,iy]
        f_new[4,ix,iy] = f[2,ix,iy]
        f_new[7,ix,iy] = f[9,ix,iy]
    end

    # Bounce Back Bottom
    iy = 1
    Threads.@threads for ix in 1:n_x
        f_new[3,ix,iy] = f[5,ix,iy]
        f_new[6,ix,iy] = f[8,ix,iy]
        f_new[7,ix,iy] = f[9,ix,iy]
    end

    # Bounce Back Top
    iy = n_y
    Threads.@threads for ix in 1:n_x
        f_new[5,ix,iy] = f[3,ix,iy]
        f_new[8,ix,iy] = f[6,ix,iy]
        f_new[9,ix,iy] = f[7,ix,iy]
    end
    
    # Inlet 
    iy = 1
    Threads.@threads for ix in x_0:x_1
        _f = f_new[:, ix, iy]
        rho = (_f[1] + _f[2] + _f[4] + 2 * (_f[5] + _f[8] + _f[9])) / (1 - v_0)
        f_new[3, ix, iy] = _f[5] + (2. / 3.) * rho * v_0 
        f_new[6, ix, iy] = _f[8] + (1. / 6.) * rho * v_0 - 0.5 * (_f[2] - _f[4])
        f_new[7, ix, iy] = _f[9] + (1. / 6.) * rho * v_0 + 0.5 * (_f[2] - _f[4])
    end

    # Outlet
    iy = n_y
    Threads.@threads for ix in x_0:x_1
        _f = f_new[:, ix, iy]
        v = (1 - (_f[1] + _f[2] + _f[4] + 2 * (_f[3] + _f[7] + _f[6]))) / (rho_0)
        f_new[5, ix, iy] = _f[3] + (2. / 3.) * rho_0 * v 
        f_new[8, ix, iy] = _f[6] + (1. / 6.) * rho_0 * v + 0.5 * (_f[2] - _f[4])
        f_new[9, ix, iy] = _f[7] + (1. / 6.) * rho_0 * v - 0.5 * (_f[2] - _f[4])
    end

    
    f .= f_new
end


function advect_g!(g, f)
    g_new = zero(g) 

    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            for i in 1:9
                ix_new = ix - c[i, 1]
                iy_new = iy - c[i, 2]

                if ix_new < 1 || ix_new > n_x || iy_new < 1 || iy_new > n_y
                    g_new[i, ix, iy] = 0.0
                else
                    g_new[i, ix, iy] = g[i, ix_new, iy_new]
                end
            end
        end
    end

    # Boundary Conditions

    x_0 = Int(floor((0.5 - 0.5 * inlet_width) * n_x))
    x_1 = Int(floor((0.5 + 0.5 * inlet_width) * n_x))

    # Adiabatic Left 
    ix = 1
    Threads.@threads for iy in 1:n_y
        _f =  f[:,ix,iy]
        v = 1 - (_f[5] + _f[1] + _f[3] + 2 * (_f[7] +  _f[4] + _f[8])) / rho_0
        T = 6 * (g_new[8,ix,iy] + g_new[4,ix,iy] + g_new[7,ix,iy]) / (1.0 - 3*v)
        g_new[6,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
        g_new[2,ix,iy] = (1.0 / 9.0) * T * (1 + 3*v)
        g_new[9,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
    end

    # Adiabatic Right
    ix = n_x
    Threads.@threads for iy in 1:n_y
        _f =  f[:,ix,iy]
        v = 1 - (_f[5] + _f[1] + _f[3] + 2 * (_f[6] + _f[2] + _f[9])) / rho_0
        T = 6 * (g_new[6,ix,iy] + g_new[2,ix,iy] + g_new[9,ix,iy]) / (1.0 - 3*v)
        g_new[8,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
        g_new[4,ix,iy] = (1.0 / 9.0) * T * (1 + 3*v)
        g_new[7,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
    end

    # Adiabatic Bottom
    iy = 1
    Threads.@threads for ix in 1:n_x
        _f =  f[:,ix,iy]
        v = 1 - (_f[1] + _f[2] + _f[4] + 2 * (_f[5] + _f[8] + _f[9])) / rho_0
        T = 6 * (g_new[8,ix,iy] + g_new[5,ix,iy] + g_new[9,ix,iy]) / (1.0 - 3*v)
        g_new[6,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
        g_new[3,ix,iy] = (1.0 / 9.0) * T * (1 + 3*v)
        g_new[7,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
    end

    # Adiabatic Top
    iy = n_y
    Threads.@threads for ix in 1:n_x
        _f = f[:,ix,iy]
        v = 1 - (_f[1] + _f[2] + _f[4] + 2 * (_f[7] + _f[3] + _f[6])) / rho_0
        T = 6 * (g_new[6,ix,iy] + g_new[3,ix,iy] + g_new[7,ix,iy]) / (1.0 - 3*v)
        g_new[8,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
        g_new[5,ix,iy] = (1.0 / 9.0) * T * (1 + 3*v)
        g_new[9,ix,iy] = (1.0 / 36.0) * T * (1 + 3*v)
    end

    # Inlet Dirichlet
    iy = 1
    Threads.@threads for ix in x_0:x_1
        _f = @view f[:,ix,iy]
        _g = @view g_new[:, ix, iy]
        v = 1 - (_f[1] + _f[2] + _f[4] + 2 * (_f[5] + _f[8] + _f[9])) / rho_0
        T = 6*(T_in - (_g[1]+_g[2]+_g[4]+_g[5]+_g[8]+_g[9])) / (1 + 3*v)
        g_new[6, ix, iy] = 1/36*T*(1+3*v)
        g_new[3, ix, iy] = 1/9*T*(1+3*v)
        g_new[7, ix, iy] = 1/36*T*(1+3*v)
    end

    g .= g_new
end



function evaluate_objective_pressure(p)
    # Inlet
    x_0 = Int(floor((0.5 - 0.5 * inlet_width) * n_x))
    x_1 = Int(floor((0.5 + 0.5 * inlet_width) * n_x))

    p_inlet = 0.0
    iy = 1
    Threads.@threads for ix in x_0:x_1
        p_inlet += p[ix, iy]
    end

    p_inlet /= (x_1 - x_0 + 1)

    # Outlet
    p_outlet = 0.0
    iy = n_y
    Threads.@threads for ix in x_0:x_1
        p_outlet += p[ix, iy]
    end

    p_outlet /= (x_1 - x_0 + 1)

    return p_inlet - p_outlet
end


function run_forward!(gamma, rho, u, v, p, q_t, T, f, g, alpha_gamma, beta_gamma, tau_f, tau_g, F, Q_t)
    x = range(0, stop=L_x, length=n_x)
    y = range(0, stop=L_y, length=n_y)

    init_pops!(f, g, rho, u, v, T)
    
    objective_pressure_transient = 0.0
    for t in 1:n_t
        if mod1(t, output_interval) == 1

            index = Int(floor(t/output_interval))

            index = lpad(index,3,"0")

            T_hm = heatmap(y, x, T)
            savefig("run/step_$(index)_T.png")
            u_hm = heatmap(y, x, sqrt.(u.^2 + v.^2))
            savefig("run/step_$(index)_u.png")
            u_x_hm = heatmap(y, x, u)
            savefig("run/step_$(index)_u_x.png")
            u_x_hm = heatmap(y, x, v)
            savefig("run/step_$(index)_u_y.png")
            F_hm = heatmap(y, x, sqrt.(F[1,:,:].^2 + F[2,:,:].^2))
            savefig("run/step_$(index)_F.png")
            rho_hm = heatmap(y, x, rho)
            savefig("run/step_$(index)_rho.png")
            gamma_hm = heatmap(y, x, gamma)
            savefig("run/step_$(index)_gamma.png")
            heatmap(y,x,p)
            savefig("run/step_$(index)_p.png")

            #println("Time: $ti")
    
        end

        relax!(f, g, p, rho, u, v, T, tau_f, tau_g)

        compute_Q_t!(Q_t, T, beta_gamma)
        compute_F!(F, u, v, alpha_gamma)

        force!(f, g, F, Q_t)

        advect_f!(f)
        advect_g!(g, f)

        compute_moments!(rho, u, v, p, q_t, T, f, g)
        
        objective_pressure = evaluate_objective_pressure(p)
        objective_pressure_transient += objective_pressure
        print("""Step: $(t), Time: $(@sprintf("%.2f", t * dt)), objective_pressure: $(@sprintf("%.4f", objective_pressure))\r""")
    end

    return objective_pressure_transient / (n_t * dt)
end


function create_gamma_from_noise!(gamma)
    noise = opensimplex2_2d()
    Threads.@threads for i in 1:n_x
        for j in 1:n_y
            xl = (i - 1 + 0.5) * dx
            yl = (j - 1 + 0.5) * dx
            
            if yl > 0.5 && yl < 1.5
                if sample(noise, 10*xl, 10*yl) > 0.7
                    gamma[i, j] = 0.0
                end
            end
        end
    end
end

# Circle in the middle
function create_gamma_test_ap!(gamma)
    Threads.@threads for i in 1:n_x
        for j in 1:n_y
            xl = (i - 1 + 0.5) * dx
            yl = (j - 1 + 0.5) * dx
            
            if (xl - 0.5)^2 + (yl - 1.0)^2 < 0.1^2
                gamma[i, j] = 0.1
            else 
                gamma[i, j] = 0.9
            end
        end
    end
end


function initial_conditions!(rho, u, v, T)
    Threads.@threads for i in 1:n_x
        for j in 1:n_y
            rho[i, j] = rho_0
            u[i, j] = 0
            v[i, j] = 0
            T[i,j] = T_0
        end
    end
end

# Equation 70
function ap_init_pops!(f_i)
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            f_i[:,ix,iy] .= 0.0
        end
    end
end

# Equation 5
function f_equilibrium!(f_eq, rho, u, v)
    for i in 1:9
        cu = c[i, 1] * u + c[i, 2] * v
        f_eq[i] = w[i] * rho * (1 + 3 * cu + 9 / 2 * cu^2 - 3 / 2 * (u^2 + v^2))
    end
end

# Equation 44
function ap_f_equilibrium!(f_i_eq, rho_i, j_i, u, v)
    for i in 1:9
        f_i_eq[i] = rho_i + 3 * ((c[i, 1] - u) * j_i[1] + (c[i, 2] - v) * j_i[2])
    end
end

# Equation 70
function ap_relax!(f_i, rho_i, j_i, u, v, tau_f)
    f_i_eq_thread_local = [zeros(Float32, 9) for i in 1:Threads.nthreads()]
    
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y

            ti = Threads.threadid()
            ap_f_equilibrium!(f_i_eq_thread_local[ti], rho_i[ix,iy], j_i[:, ix, iy], u[ix,iy], v[ix,iy])

            for i in 1:9
                f_i[i,ix,iy] = f_i[i,ix,iy] - 1/tau_f * (f_i[i,ix,iy] - f_i_eq_thread_local[ti][i])
            end
        end
    end
end

function ap_compute_F!(F_i, m_i, alpha_gamma)
    F_i[1, :, :] .= - alpha_gamma .* m_i[1, :, :]
    F_i[2, :, :] .= - alpha_gamma .* m_i[2, :, :]
end

function ap_force!(f_i, F_i)
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            for i in 1:9
                f_i[i,ix,iy] = f_i[i,ix,iy] + 3.0 * dx*w[i]*(c[i,1]*F_i[1,ix,iy] + c[i,2]*F_i[2,ix,iy])
            end
        end
    end
end

function ap_advect_f!(f_i)
    f_i_new = zero(f_i) 

    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            for i in 1:9
                ix_new = ix + c[i, 1]
                iy_new = iy + c[i, 2]

                if ix_new < 1 || ix_new > n_x || iy_new < 1 || iy_new > n_y
                    f_i_new[i, ix, iy] = 0.0
                else
                    f_i_new[i, ix, iy] = f_i[i, ix_new, iy_new]
                end
            end
        end
    end

    ## Boundary Conditions

    x_0 = Int(floor((0.5 - 0.5 * inlet_width) * n_x))
    x_1 = Int(floor((0.5 + 0.5 * inlet_width) * n_x))

    # Bounce Back Left 
    ix = 1
    Threads.@threads for iy in 1:n_y
        f_i_new[8,ix,iy] = f_i[6,ix,iy]
        f_i_new[4,ix,iy] = f_i[2,ix,iy]
        f_i_new[7,ix,iy] = f_i[9,ix,iy]
    end

    # Bounce Back Right
    ix = n_x
    Threads.@threads for iy in 1:n_y
        f_i_new[6,ix,iy] = f_i[8,ix,iy]
        f_i_new[2,ix,iy] = f_i[4,ix,iy]
        f_i_new[9,ix,iy] = f_i[7,ix,iy]
    end

    # Bounce Back Bottom
    iy = 1
    Threads.@threads for ix in 1:n_x
        f_i_new[5,ix,iy] = f_i[3,ix,iy]
        f_i_new[8,ix,iy] = f_i[6,ix,iy]
        f_i_new[9,ix,iy] = f_i[7,ix,iy]
    end

    # Bounce Back Top
    iy = n_y
    Threads.@threads for ix in 1:n_x
        f_i_new[3,ix,iy] = f_i[5,ix,iy]
        f_i_new[6,ix,iy] = f_i[8,ix,iy]
        f_i_new[7,ix,iy] = f_i[9,ix,iy]
    end
    
    # Inlet 
    iy = 1
    Threads.@threads for ix in x_0:x_1
        _f_i = f_i_new[:, ix, iy]
        rho_i = - 2 / ( 3 * (1 - v_0)) + (v_0 / (3*(1 - v_0))) * (4 * _f_i[3] + _f_i[6] + _f_i[7])
        f_i_new[5, ix, iy] = _f_i[3] + rho_i
        f_i_new[8, ix, iy] = _f_i[6] + rho_i
        f_i_new[9, ix, iy] = _f_i[7] + rho_i
    end

    # Outlet
    iy = n_y
    Threads.@threads for ix in x_0:x_1
        _f_i = f_i_new[:, ix, iy]
        v_i = (1. / 3.) * (4*_f_i[5] + _f_i[8] + _f_i[9])
        f_i_new[3, ix, iy] = _f_i[5] - v_i
        f_i_new[6, ix, iy] = _f_i[8] - v_i
        f_i_new[7, ix, iy] = _f_i[9] - v_i
    end

    
    f_i .= f_i_new
end

function ap_compute_moments(rho_i, j_i, m_i, f_i, u, v)
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            rho_i[ix, iy] = 0
            j_i[:, ix, iy] .= 0
            m_i[:, ix, iy] .= 0

            for i in 1:9
                rho_i[ix, iy] += w[i] * f_i[i, ix, iy] * (1.0 + 3.0 * (c[i, 1] * u[ix, iy] + c[i, 2] * v[ix, iy]) + 9.0 / 2.0 * (c[i, 1] * u[ix, iy] + c[i, 2] * v[ix, iy])^2 - 3.0 / 2.0 * (u[ix, iy]^2 + v[ix, iy]^2))
                cu = c[i, 1] * u[ix, iy] + c[i, 2] * v[ix, iy]

                j_i[1, ix, iy] += w[i] * f_i[i, ix, iy] * (c[i, 1] + 3.0 * (cu * c[i, 1]) - u[ix, iy])
                j_i[2, ix, iy] += w[i] * f_i[i, ix, iy] * (c[i, 2] + 3.0 * (cu * c[i, 2]) - v[ix, iy])

                m_i[1, ix, iy] += w[i] * f_i[i, ix, iy] * c[i, 1]
                m_i[2, ix, iy] += w[i] * f_i[i, ix, iy] * c[i, 2]
            end
        end
    end
end

# ap: adjoint pressure minimization equation
function run_ap(f_i, rho_i, j_i, m_i, F_i, u, v, alpha_gamma, tau_f)
    x = range(0, stop=L_x, length=n_x)
    y = range(0, stop=L_y, length=n_y)

    # init_pops
    ap_init_pops!(f_i)

    # main loop
    for t in 1:n_t
        if mod1(t, output_interval) == 1

            index = Int(floor(t/output_interval))

            index = lpad(index,3,"0")

            m_i_hm = heatmap(y, x, sqrt.(m_i[1, :, :].^2 + m_i[2, :, :].^2))
            savefig("run/step_$(index)_m_i.png")
            j_i_hm = heatmap(y, x, sqrt.(j_i[1, :, :].^2 + j_i[2, :, :].^2))
            savefig("run/step_$(index)_j_i.png")
            m_i_x_hm = heatmap(y, x, (m_i[1, :, :]))
            savefig("run/step_$(index)_m_i_x.png")
            m_i_x_hm = heatmap(y, x, (m_i[2, :, :]))
            savefig("run/step_$(index)_m_i_y.png")
            F_i_hm = heatmap(y, x, sqrt.(F_i[1,:,:].^2 + F_i[2,:,:].^2))
            savefig("run/step_$(index)_F_i.png")
            rho_i_hm = heatmap(y, x, rho_i)
            savefig("run/step_$(index)_rho_i.png")

            #println("Time: $ti")
    
        end

        # relax
        ap_relax!(f_i, rho_i, j_i, u, v, tau_f)
        
        # compute forces
        ap_compute_F!(F_i, m_i, alpha_gamma)

        # apply forces
        ap_force!(f_i, F_i)

        # advect
        ap_advect_f!(f_i)

        # compute moments
        ap_compute_moments(rho_i, j_i, m_i, f_i, u, v)

        print("Step: $(t), Time: $(t * dt)\r")
    end
end

function ap_compute_sensitivity!(dJdgamma, u, v, m_i, gamma)
    Threads.@threads for ix in 1:n_x
        for iy in 1:n_y
            um = u[ix, iy] * m_i[1, ix, iy] + v[ix, iy] * m_i[2, ix, iy]
            alpha_gamma_prime = (alpha_min - alpha_max) * (1 - gamma[ix, iy] / (gamma[ix, iy] + ramp_alpha)) * (1 + ramp_alpha)  / (gamma[ix, iy] + ramp_alpha)
            dJdgamma[ix, iy] = 3 * alpha_gamma_prime * um
        end
    end

    # normalize
    dJdgamma ./= L_x * L_y
end


function test_ap_adjoint()
    x = range(0, stop=L_x, length=n_x)
    y = range(0, stop=L_y, length=n_y)

    # allocation
    gamma = ones(Float32, n_x, n_y)
    create_gamma_from_noise!(gamma)

    # gamma .*= 1.

    for i in 1:100
        rho = zeros(Float32, n_x, n_y)
        u = zeros(Float32, n_x, n_y)
        v = zeros(Float32, n_x, n_y)
        p = zeros(Float32, n_x, n_y)
        q_t = zeros(Float32, 2, n_x, n_y)
        T = zeros(Float32, n_x, n_y)

        f = zeros(Float32, 9, n_x, n_y)
        g = zeros(Float32, 9, n_x, n_y)

        F = zeros(Float32, 2, n_x, n_y)
        Q_t = zeros(Float32, n_x, n_y)

        # adjoint
        f_i = zeros(Float32, 9, n_x, n_y)
        rho_i = zeros(Float32, n_x, n_y)
        j_i = zeros(Float32, 2, n_x, n_y)
        m_i = zeros(Float32, 2, n_x, n_y)

        F_i = zeros(Float32, 2, n_x, n_y)

        # sensitivity
        dJdgamma = zeros(Float32, n_x, n_y)

        # initial conditions
        # create_gamma_test_ap!(gamma)


        # tau_f = compute_tau_f()$
        tau_f = 0.8
        tau_g = compute_tau_g()

        alpha_gamma = compute_alpha_gamma(gamma)
        beta_gamma = compute_beta_gamma(gamma)

        initial_conditions!(rho, u, v, T)
    
        # run forward
        objective_pressure_transient = run_forward!(gamma, rho, u, v, p, q_t, T, f, g, alpha_gamma, beta_gamma, tau_f, tau_g, F, Q_t)
        
        println("\n Objective Transient Pressure: $objective_pressure_transient")

        # adjoint
        run_ap(f_i, rho_i, j_i, m_i, F_i, u, v, alpha_gamma, tau_f) 

        ap_compute_sensitivity!(dJdgamma, u, v, m_i, gamma)

        # plot sensitivity
        sensitivity = heatmap(y, x, dJdgamma)
        savefig("run/sensitivity_$(i).png")
        
        # steepest descent
        gamma .-= 100 * dJdgamma
        gamma = clamp.(gamma, 0, 1)

        # plot gamma
        gamma_hm = heatmap(y, x, gamma)
        savefig("run/gamma_$(i).png")

        alpha_gamma = compute_alpha_gamma(gamma)
        beta_gamma = compute_beta_gamma(gamma)
    end
end

function main()
    `rm run/"*"`
    # allocation
    # forward
    gamma = ones(Float32, n_x, n_y)
    rho = zeros(Float32, n_x, n_y)
    u = zeros(Float32, n_x, n_y)
    v = zeros(Float32, n_x, n_y)
    p = zeros(Float32, n_x, n_y)
    q_t = zeros(Float32, 2, n_x, n_y)
    T = zeros(Float32, n_x, n_y)

    f = zeros(Float32, 9, n_x, n_y)
    g = zeros(Float32, 9, n_x, n_y)

    F = zeros(Float32, 2, n_x, n_y)
    Q_t = zeros(Float32, n_x, n_y)

    # adjoint
    f_i = zeros(Float32, 9, n_x, n_y)
    rho_i = zeros(Float32, n_x, n_y)
    j_i = zeros(Float32, 2, n_x, n_y)
    m_i = zeros(Float32, 2, n_x, n_y)

    F_i = zeros(Float32, 2, n_x, n_y)

    # initial conditions
    create_gamma_from_noise!(gamma)

    # tau_f = compute_tau_f()$
    tau_f = 0.8
    tau_g = compute_tau_g()

    alpha_gamma = compute_alpha_gamma(gamma)
    beta_gamma = compute_beta_gamma(gamma)

    initial_conditions!(rho, u, v, T)

    # run forward
    objective_pressure_transient = run_forward!(gamma, rho, u, v, p, q_t, T, f, g, alpha_gamma, beta_gamma, tau_f, tau_g, F, Q_t)
    
    println("\n Objective Transient Pressure: $objective_pressure_transient")

    # adjoint
    run_ap(f_i, rho_i, j_i, m_i, F_i, u, v, alpha_gamma, tau_f)

    # sensitivity computation
end

end