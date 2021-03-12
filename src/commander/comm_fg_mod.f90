!****************************************************************************
!*                                                                          *
!*             MCMC engine for foreground sampling in Commander             *
!*                                                                          *
!*          Written by Hans Kristian Eriksen, JPL, April-July 2007          *
!*                                                                          *
!****************************************************************************
module comm_fg_mod
  use comm_fg_component_mod
  use comm_N_mult_mod
  use comm_task_mod
  use powell_mod
  use comm_genvec_mod
  use comm_chisq_mod
  use ARS_mod
  use InvSamp_mod
  implicit none

  integer(i4b),       private  :: comm_chain, myid_chain, comm_alms, myid_alms, numprocs_chain
  integer(i4b),       private  :: chain, root, ierr, verbosity, nind
  real(dp),           private  :: rms_specind
  type(planck_rng),   private  :: handle
  character(len=128), private  :: mode, operation
  logical(lgt),       private  :: first_call = .true., enforce_zero_cl

  integer(i4b), dimension(MPI_STATUS_SIZE),          private :: status

  real(dp), allocatable, dimension(:),   private :: my_residual, my_inv_N
  real(dp), allocatable, dimension(:,:), private :: all_residuals, all_inv_N
  real(dp),                              private :: chisq_threshold

  ! Internal data set for adaptive rejection sampler
  integer(i4b),                                 private :: npix_reg, comp_reg, p_reg, p_local_reg
  integer(i4b),    allocatable, dimension(:,:), private :: pix_reg
  logical(lgt),    allocatable, dimension(:),   private :: inc_band
  real(dp),                                     private :: P_gauss_reg(2), par_old, P_uni_reg(2)
  real(dp),                                     private :: N_scale
  integer(i4b),    allocatable, dimension(:),   private :: s_reg
  real(dp),        allocatable, dimension(:),   private :: amp_reg, w_reg, scale_reg
  real(dp),        allocatable, dimension(:),   private :: vmap_reg
  real(dp),        allocatable, dimension(:,:), private :: d_reg, invN_reg
  real(dp),        allocatable, dimension(:),   private :: x_def
  type(fg_params), allocatable, dimension(:),   private :: fg_par_reg

  integer(i4b),                                 private :: namp, blocksize
  real(dp),        allocatable, dimension(:),   private :: p_default

  integer(i4b), private :: pix_init, s_init

contains

  ! *********************************************************
  ! *                Initialization routines                *
  ! *********************************************************

  subroutine initialize_fg_mod(chain_in, comm_chain_in, comm_alms_in, handle_in, paramfile)
    implicit none

    character(len=128),                intent(in)    :: paramfile
    integer(i4b),                      intent(in)    :: comm_chain_in, comm_alms_in, chain_in
    type(planck_rng),                  intent(inout) :: handle_in

    integer(i4b) :: i, j, k, l, ll, m, ierr, pol_ind, seed, fac, numval
    character(len=2)   :: map_text
    character(len=128) :: filename, paramtext

    chain      = chain_in
    comm_chain = comm_chain_in
    comm_alms  = comm_alms_in
    root       = 0
    call mpi_comm_rank(comm_alms,  myid_alms,  ierr)
    call mpi_comm_rank(comm_chain, myid_chain, ierr)
    call mpi_comm_size(comm_chain, numprocs_chain, ierr)

    call init_comm_fg_component_mod(paramfile, comm_chain)
    call get_parameter(paramfile, 'VERBOSITY',                  par_int=verbosity)
    call get_parameter(paramfile, 'OPERATION',                  par_string=operation)
    call get_parameter(paramfile, 'SAMPLE_TT_MODES',            par_lgt=sample_T_modes)
    call get_parameter(paramfile, 'ENFORCE_ZERO_CL',            par_lgt=enforce_zero_cl)
    call get_parameter(paramfile, 'SPECIND_SAMPLER_BLOCKSIZE',  par_int=blocksize)
    call get_parameter(paramfile, 'RMS_SPEC_INDEX_RANDOM_WALK', par_dp=rms_specind)

    ! Initialize random number generator
    seed = nint(10000000.*rand_uni(handle_in))
    call rand_init(handle, seed)

  end subroutine initialize_fg_mod


  subroutine cleanup_fg_mod
    implicit none

  end subroutine cleanup_fg_mod


  subroutine sample_fg_pix_response_map(s, residuals_in, inv_N_in, fg_amp_in, fg_param_map, stat)
    implicit none
    
    type(genvec),                     intent(in),    optional :: s
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: residuals_in, fg_amp_in
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: inv_N_in
    real(dp), dimension(0:,1:,1:),    intent(inout), optional :: fg_param_map
    integer(i4b),                     intent(inout), optional :: stat

    integer(i4b) :: b, i, j, k, l, m, n, p, q, r, fac, mystat, pix, c, test
    logical(lgt) :: accept
    real(dp)     :: chisq_prop, chisq0, chisq0_rms, chisq_prop_rms, accept_prob
    real(dp)     :: buffer, chisq_in, chisq_out, Delta, t1, t2
    real(dp), allocatable, dimension(:,:,:)   :: par_prop, par0, par_smooth
    real(dp), allocatable, dimension(:,:,:)   :: residuals, fg_amp
    real(dp), allocatable, dimension(:,:,:)   :: inv_N
    real(dp), allocatable, dimension(:,:)     :: chisq_map
    real(dp), allocatable, dimension(:), save :: N_accept, N_total

    ! If there are no parameters, don't try to sample them
    if (num_fg_par == 0) return

    if (.not. allocated(N_accept)) then
       allocate(N_accept(num_fg_par), N_total(num_fg_par))
       N_accept = 0.d0; N_total = 0.d0
    end if

    allocate(par_prop(0:npix-1,nmaps,num_fg_par), par0(0:npix-1,nmaps,num_fg_par))
    allocate(par_smooth(0:npix-1,nmaps,num_fg_par))
    allocate(chisq_map(0:npix-1,1))
    if (myid_chain == root) par0 = fg_param_map
    call mpi_bcast(par0, size(par0), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call get_smooth_par_map(par0, par_smooth)

    ! Distribute information
    allocate(residuals(0:npix-1,nmaps,numband))
    allocate(inv_N(0:npix-1,nmaps,numband))
    allocate(fg_amp(0:npix-1,nmaps,num_fg_comp))
    
    if (myid_chain == root) then
       residuals = residuals_in
       inv_N     = inv_N_in
       fg_amp    = fg_amp_in
    end if
    
    call mpi_bcast(residuals, size(residuals), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(inv_N,     size(inv_N),     MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(fg_amp,    size(fg_amp),    MPI_DOUBLE_PRECISION, root, comm_chain, ierr)

    ! Sample spectral indices for each parameter
    p        = 1
    mystat    = 0
    do i = 1, num_fg_comp
       do j = 1, fg_components(i)%npar
          if (fg_components(i)%gauss_prior(j,2) == 0.d0) then
             p = p+1
             cycle
          end if
          do r = 1, fg_components(i)%indregs(j)%nregset
             if (myid_chain == root .and. verbosity >= 3) write(*,fmt='(a,a,a,a,a,i4)') 'Sampling fg_par -- ', &
                  & trim(fg_components(i)%label), ' ', trim(fg_components(i)%indlabel(j)), ', regset = ', r

             do b = 1, fg_components(i)%indregs(j)%regset(r)%n/blocksize+1

                ! Propose a sample for all regions
                par_prop       = par0
                chisq_prop_rms = 0.d0
                chisq0_rms     = 0.d0
                !call wall_time(t1)
                if (.false.) then
                   if (myid_chain == root) then
                      do k = 1+myid_chain, fg_components(i)%indregs(j)%regset(r)%n
                         q = fg_components(i)%indregs(j)%regset(r)%r(k)
                         call sample_spec_index_single_region(residuals, inv_N, fg_amp, &
                              & fg_components(i)%indregs(j)%regions(q), p, j, i, par_prop, par_smooth,mystat, &
                              & chisq_in=chisq_in, chisq_out=chisq_out)
                         chisq_prop_rms = chisq_prop_rms + chisq_out
                         chisq0_rms     = chisq0_rms     + chisq_in
                      end do
                   end if
                else
                   ! do k = 1+myid_chain, fg_components(i)%indregs(j)%regset(r)%n, numprocs_chain
                   do k = (b-1)*blocksize+1+myid_chain, &
                        & min(b*blocksize,fg_components(i)%indregs(j)%regset(r)%n), numprocs_chain
                      q = fg_components(i)%indregs(j)%regset(r)%r(k)
                      call sample_spec_index_single_region(residuals, inv_N, fg_amp, &
                           & fg_components(i)%indregs(j)%regions(q), p, j, i, par_prop, par_smooth, &
                           & mystat, chisq_in=chisq_in, chisq_out=chisq_out)
                      if (par_prop(fg_components(i)%indregs(j)%regions(q)%pix(1,1),1,p) /= &
                           & par_prop(fg_components(i)%indregs(j)%regions(q)%pix(1,1),1,p)) then
                         write(*,*) 'pix = ', par_prop(fg_components(i)%indregs(j)%regions(q)%pix(1,1),1,p)
                         write(*,*) i, j, r, k, q
                         stop
                      end if
                      chisq_prop_rms = chisq_prop_rms + chisq_out
                      chisq0_rms     = chisq0_rms     + chisq_in
                   end do
                end if
                !call wall_time(t2)
                !if (myid_chain == root) write(*,*) 'proposal', i, j, r, real(t2-t1,sp)
                
                ! Synchronize all proposals
                call mpi_allreduce(chisq_prop_rms, buffer, 1, MPI_DOUBLE_PRECISION, MPI_SUM, comm_chain, ierr)
                chisq_prop_rms = buffer
                call mpi_allreduce(chisq0_rms, buffer, 1, MPI_DOUBLE_PRECISION, MPI_SUM, comm_chain, ierr)
                chisq0_rms = buffer
                !if (chisq_prop_rms == chisq0_rms) cycle
                if (myid_chain == root) then
                   fg_param_map(:,:,p) = par_prop(:,:,p)
                   do k = 1, numprocs_chain-1
                      call mpi_recv(par_prop(:,:,p), size(par_prop(:,:,p)),&
                           & MPI_DOUBLE_PRECISION, k, 61, comm_chain, status, ierr)  
                      do l = (b-1)*blocksize+1+k, &
                           & min(b*blocksize,fg_components(i)%indregs(j)%regset(r)%n), numprocs_chain
                         !do l = 1+k, fg_components(i)%indregs(j)%regset(r)%n, numprocs_chain       
                         q = fg_components(i)%indregs(j)%regset(r)%r(l)
                         do m = 1, fg_components(i)%indregs(j)%regions(q)%n
                            pix = fg_components(i)%indregs(j)%regions(q)%pix(m,1)
                            c   = fg_components(i)%indregs(j)%regions(q)%pix(m,2)
                            fg_param_map(pix,c,p) = par_prop(pix,c,p)
                         end do
                      end do
                   end do
                   par_prop(:,:,p) = fg_param_map(:,:,p)
                else
                   call mpi_send(par_prop(:,:,p), size(par_prop(:,:,p)), MPI_DOUBLE_PRECISION, root, 61, &
                        & comm_chain, ierr)
                end if
                call mpi_bcast(par_prop, size(par_prop), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
                
                if (trim(noise_format) /= 'rms') then
                   ! Enforce accept/reject probability
                   if (myid_chain == root) then
                      call compute_total_chisq(map_id, s=s, index_map=par_smooth, chisq_fullsky=chisq0)
                      call get_smooth_par_map(par_prop, par_smooth)
                      call compute_total_chisq(map_id, s=s, index_map=par_smooth, chisq_fullsky=chisq_prop)
                      ! Prior term is neglected, since it cancels due to our proposal distribution
                      !Delta = (chisq_prop-chisq_prop_rms)-(chisq0-chisq0_rms)
                      Delta = (chisq_prop-chisq0) + (chisq_prop_rms-chisq0_rms) ! Simple MH
                      if (rms_specind > 0.d0 .or. trim(operation) == 'optimize') then
                         if (chisq_prop < chisq0) then
                            accept_prob = 1.d0
                         else
                            accept_prob = 0.d0
                         end if
                      else
                         if (Delta < 0.d0) then
                            accept_prob = 1.d0
                         else
                            accept_prob = exp(-0.5d0*Delta)
                         end if
                      end if
                      accept = rand_uni(handle) < accept_prob
                      N_total(p) = N_total(p) + 1.d0
                      if (accept) N_accept(p) = N_accept(p) + 1.d0
                      if (verbosity > 1 .and. mod(b,1) == 0) then
                         write(*,*) '     Block     = ', b, ' of ', &
                              & fg_components(i)%indregs(j)%regset(r)%n/blocksize+1
                         write(*,fmt='(a8,a,a8,a,f6.2,a,l2,a,f6.2)') trim(fg_components(i)%label), ' ', &
                              & trim(fg_components(i)%indlabel(j)), &
                              & ' --  p_accept = ', real(accept_prob,sp), ', accept = ', accept, &
                              & ', accept rate = ', real(N_accept(p)/N_total(p),sp)
                         write(*,*) '     Chisq0     = ', chisq0, chisq0_rms
                         write(*,*) '     Chisq_prop = ', chisq_prop, chisq_prop_rms
                         write(*,*) '     Delta      = ', Delta
                      end if
                      
                   else
                      call compute_total_chisq(map_id)
                      call compute_total_chisq(map_id)
                   end if
                   call mpi_bcast(accept, 1, MPI_LOGICAL, root, comm_chain, ierr)
                   if (accept) par0 = par_prop
                else
                   accept = .true.
                   par0   = par_prop
                end if
                
                !             call mpi_finalize(ierr)
                !             stop
                
                call get_smooth_par_map(par0, par_smooth)
                
                !             if (myid_chain == root) write(58,*) test, maxval(par_prop(:,1,p)), chisq_out
                !write(*,*) test, maxval(par_prop(:,1,p)), chisq_out
             end do
          end do
          !close(58)


 !         call mpi_finalize(ierr)
 !         stop

          !end do

          p = p+1
       end do
    end do

    call mpi_reduce(mystat, i, 1, MPI_INTEGER, MPI_SUM, root, comm_chain, ierr)
    if (myid_chain == root) then
       fg_param_map = par0
       stat         = i
    end if

    first_call = .false.

    deallocate(par0, par_prop, par_smooth, chisq_map)
    deallocate(residuals)
    deallocate(inv_N)
    deallocate(fg_amp)

  end subroutine sample_fg_pix_response_map

 
  ! *************************************************
  ! *                Engine routines                *
  ! *************************************************

  subroutine sample_spec_index_single_region(data, inv_N_rms, amp, region, p, p_local, comp, par_map, &
       & par_smooth, stat, chisq_in, chisq_out)
    implicit none

    real(dp), dimension(0:,1:,1:),    intent(in)     :: data, amp
    real(dp), dimension(0:,1:,1:),    intent(in)     :: inv_N_rms
    type(fg_region),                  intent(inout)  :: region
    integer(i4b),                     intent(in)     :: p, p_local, comp
    real(dp), dimension(0:,1:,1:),    intent(inout)  :: par_map, par_smooth
    integer(i4b),                     intent(out)    :: stat
    real(dp),                         intent(out), optional :: chisq_in, chisq_out

    integer(i4b)     :: i, j, k, n, pix, s, status, ind(1)
    real(dp)         :: x_init(num_recent_point), par, par_1D(1), tmp, delta, t1, t2, chisq0, chisq, p_test
    real(dp)         :: chisq_old, alpha
    real(dp), allocatable, dimension(:) :: x_n, S_n
    logical(lgt)     :: return_prior
    character(len=5) :: id_text

    integer(i4b), save :: iteration = 0
    
    alpha = 1.d0

!!$    if (trim(noise_format) /= 'rms') then
!!$       write(*,*) 'ERROR -- MUST BE FIXED!!'
!!$       alpha = 0.05d0
!!$       par = par_map(region%pix(1,1),region%pix(1,2),p) 
!!$       chisq_in = (par+3.1d0)**2 / 0.3d0**3
!!$       par = par + alpha * rand_gauss(handle)
!!$       chisq_out = (par+3.1d0)**2 / 0.3d0**3
!!$       do i = 1, region%n
!!$          par_map(region%pix(i,1),region%pix(i,2),p) = par
!!$       end do
!!$       return
!!$    end if


    ! Prepare reduced data set
    npix_reg = region%n_ext
    allocate(d_reg(npix_reg,numband), amp_reg(npix_reg), invN_reg(npix_reg,numband))
    allocate(vmap_reg(npix_reg))
    allocate(s_reg(npix_reg), fg_par_reg(npix_reg), w_reg(npix_reg))
    allocate(pix_reg(npix_reg,2), inc_band(numband))
    par_old = par_map(region%pix(1,1),region%pix(1,2),p)
    inc_band = .true.
    if (trim(fg_components(comp)%type) == 'CO_multiline') then
       inc_band                                         = .false.
       inc_band(fg_components(comp)%co_band(p_local+1)) = .true.
    elseif (trim(fg_components(comp)%type) == 'CO_velocity') then
       ! find band number corresponding to CO parameter p_local 
       inc_band                                         = .false.
       if (p_local > fg_components(comp)%nharm) then ! p_local is a tilt parameter, subtract nharm from p_local
          inc_band(fg_components(comp)%co_band(p_local-fg_components(comp)%nharm)) = .true.
       else ! add 1 to p_local as co_band(1) is the reference band
          inc_band(fg_components(comp)%co_band(p_local+1)) = .true.
       end if
    end if
    call cpu_time(t1)
    pix_reg     = region%pix_ext
    do i = 1, npix_reg
       pix = region%pix_ext(i,1)
       s   = region%pix_ext(i,2)
       ! Compute signal for the current component
       call reorder_fg_params(par_smooth(pix,:,:), fg_par_reg(i))
       d_reg(i,:)  = data(pix,s,:)
       amp_reg(i)  = amp(pix,s,comp)
       if (trim(fg_components(comp)%type) == 'CO_velocity') then
          vmap_reg(i) = fg_components(comp)%vmap(pix,1) !set vmap value for the pixels in the region
       end if
       s_reg(i)    = s
       w_reg(i)    = region%w(i)
       comp_reg    = comp
       p_reg       = p
       p_local_reg = p_local
       do j = 1, num_fg_comp
          if (j /= comp) then
             do k = 1, numband
                if (inc_band(k)) then
                   if (j == 1) then
                      if (fg_par_reg(i)%comp(j)%p(s,1) > 6.d0) then
                         write(*,*) 'a'
                         write(*,*) i, fg_par_reg(i)%comp(j)%p(s,:)
                         stop
                      end if
                   end if
                   d_reg(i,k) = d_reg(i,k) - get_effective_fg_spectrum(fg_components(j), k, &
                        & fg_par_reg(i)%comp(j)%p(s,:), pixel=pix, pol=s) * amp(pix,s,j)
                end if
             end do
          end if
       end do

       ! Set up inverse covariance
       do j = 1, numband
          invN_reg(i,j) = inv_N_rms(pix,s,j)
       end do
       if (fg_components(comp)%indmask(pix,s) < 0.5d0) invN_reg(i,:) = 0.d0
    end do

    !write(*,fmt='(a,3e16.8)') 'data = ', sum(abs(d_reg)), sum(abs(invN_reg)), sum(abs(amp_reg))

    if (sum(abs(invN_reg)) == 0.d0) then
       ! No data available; leave unchanged
       deallocate(d_reg, amp_reg, invN_reg, s_reg, fg_par_reg, w_reg, pix_reg, inc_band)
       return
    end if

    ! Set up prior
    P_gauss_reg = fg_components(comp)%gauss_prior(p_local,1:2)
    P_uni_reg   = fg_components(comp)%priors(p_local,1:2)
    if (present(chisq_in)) chisq_in = -2.d0*lnL_specind_ARS(par_old)

    if (trim(fg_components(comp)%type) == 'CO_multiline') then 

       ! Draw amplitude with Gaussian sampler
       par = sample_CO_line(comp, fg_components(comp)%co_band(p_local+1))
       do i = 1, region%n
          par_map(region%pix(i,1),region%pix(i,2),p_reg) = par
       end do
       if (present(chisq_out)) chisq_out = -2.d0*lnL_specind_ARS(par)

    elseif (trim(fg_components(comp)%type) == 'CO_velocity') then 
       ! Note!
       ! p is a global counter for the spectral parameters (starting from parameter 1 of component 1)
       ! p_local is the counter of the spectral parameters of the current CO_velocity component
       ! i.e. if p_local > nharm (number of harmonics), hten p is a tilt parameter and the co_band
       ! is given by p_local-nharm, and line ratios are given by p-nharm (except if p_local == nharm+1)

       ! par_map(1,1,p) is the tilt of the reference band
       ! the (1,1,p) is just pixel 1 in map 1 for parameter p (LR and tilt are fullsky anyways)
       ! the parameter passed to the sampling functions are the corresponding line ratio/tilt of the same band
       ! this is so that one can subtract the data from the reduced data set (see the functions)

       ! Draw amplitude with Gaussian sampler (similar to CO multiline)
       if (p_local == fg_components(comp)%nharm+1) then ! sampling tilt of reference band
          par = sample_CO_tilt_velocity(comp, fg_components(comp)%co_band(p_local- &
               & fg_components(comp)%nharm),par_map(1,1,p),p_local, &
               & fg_components(comp)%nu_ref)
       else if (p_local > fg_components(comp)%nharm + 1) then ! sampling tilt of harmonics
          par = sample_CO_tilt_velocity(comp, fg_components(comp)%co_band(p_local- &
               & fg_components(comp)%nharm),par_map(1,1,p-(fg_components(comp)%nharm+1)), &
               & p_local, fg_components(comp)%nu_ref)
       else ! sampling Line ratio
          par = sample_CO_lr_velocity(comp, fg_components(comp)%co_band(p_local+1), &
               & par_map(1,1,p+(fg_components(comp)%nharm+1)),p_local, &
               & fg_components(comp)%nu_ref)
       end if

       ! set the global parameter map to the newly sampled value
       do i = 1, region%n
          par_map(region%pix(i,1),region%pix(i,2),p_reg) = par
       end do
       if (present(chisq_out)) chisq_out = -2.d0*lnL_specind_ARS(par)

    else
       
       ! Check if we are strongly at prior edges; in that case, return prior
       delta = 1.d-9 * (P_uni_reg(2)-P_uni_reg(1))
       return_prior = .false.
       if (lnL_specind_ARS(P_uni_reg(1))-lnL_specind_ARS(P_uni_reg(1)+delta) > 25.d0) then          
!          write(*,*) 'low pix_reg = ', pix_reg
!          write(*,*) 'low lnL     = ', lnL_specind_ARS(P_uni_reg(1))
          par = P_uni_reg(1)
          return_prior = .true.
       else if (lnL_specind_ARS(P_uni_reg(2))-lnL_specind_ARS(P_uni_reg(2)-delta) > 25.d0) then
!          write(*,*) 'high pix_reg = ', pix_reg
!          write(*,*) 'high lnL     = ', lnL_specind_ARS(P_uni_reg(2))
          par = P_uni_reg(2)
          return_prior = .true.
       end if
       
       if (.not. return_prior) then
          
          ! Set up initial point; remove duplicates
          x_init = region%recent
          call QuickSort_real(x_init)
          n = num_recent_point
          i = 2
          do while (i <= n)
             if (x_init(i) == x_init(i-1)) then
                x_init(i:n-1) = x_init(i+1:n)
                n             = n-1
             else
                i = i+1
             end if
          end do
          
          if (.true.) then
             ! Do a non-linear optimization to find start point
             status = 0
             par_1D = par_old
             chisq_old = -2.d0 * lnL_specind_ARS(par_old)
!             write(*,*) par_old, chisq_old
             call powell(par_1D, neg_lnL_specind_ARS, status)
             chisq = -2.d0 * lnL_specind_ARS(par_1D(1))
!             write(*,*) par_1D(1), chisq
!             call mpi_finalize(ierr)
!             stop
             if (chisq > chisq_old) then
                write(*,*) 'Error -- powell failed'
                write(*,*) chisq, chisq_old
                stop
             end if

             x_init(2) = par_1D(1)
             if (P_gauss_reg(2) > 0.d0) then
                x_init(1) = max(x_init(2)-P_gauss_reg(2), P_uni_reg(1))
                x_init(3) = min(x_init(2)+P_gauss_reg(2), P_uni_reg(2))
             else
                x_init(1) = max(x_init(2)-1.d-3*(P_uni_reg(2)-P_uni_reg(1)), P_uni_reg(1))
                x_init(3) = min(x_init(2)+1.d-3*(P_uni_reg(2)-P_uni_reg(1)), P_uni_reg(2))
             end if
             if (abs(x_init(2)-x_init(1)) < 1.d-6*(P_uni_reg(2)-P_uni_reg(1))) x_init(2) = 0.5d0*(x_init(1)+x_init(3))
             if (abs(x_init(2)-x_init(3)) < 1.d-6*(P_uni_reg(2)-P_uni_reg(1))) x_init(2) = 0.5d0*(x_init(1)+x_init(3))       
                      
             if (rms_specind > 0.d0) then
                par = max(min(par_old + rms_specind * rand_gauss(handle), P_uni_reg(2)), P_uni_reg(1))
             else if (trim(operation) == 'optimize') then
                par = par_old + alpha*(par_1D(1)-par_old)
             else
                ! Draw an actual sample
                par = sample_InvSamp(handle, x_init, lnL_specind_ARS, fg_components(comp)%priors(p_local,1:2), &
                     & status=status)

             end if
                
             if (status /= 0) then
                ! Return ML point if sampling failed; this needs to be fixed!
                par    = par_1D(1)
                status = 0
             end if

          end if
          
!!$    call write_map('spec_in.fits', par_map(:,:,p_reg))
!!$    call write_map('spec_smooth.fits', par_smooth(:,:,p_reg))
!!$    n = 2
!!$    do i = 1, npix_reg
!!$       mypar(1:n) = fg_par_reg(i)%comp(comp_reg)%p(s_reg(i),1:n)
!!$       mypar(p_local_reg) = max(min(mypar(p_local_reg) + w_reg(i) * (par-par_old), P_uni_reg(2)), &
!!$            & P_uni_reg(1))
!!$       par_smooth(region%pix_ext(i,1),1,p_reg) = mypar(p_local_reg)
!!$    end do
!!$    call write_map('spec_out.fits', par_smooth(:,:,p_reg))


          if (status == 0) then
             par = max(min(par, P_uni_reg(2)), P_uni_reg(1))
             do i = 1, region%n
                par_map(region%pix(i,1),region%pix(i,2),p_reg) = par
             end do

!!$             !call int2string(myid_chain, id_text)
!!$             if (comp == 1 .and. p_local == 2 .and. region%pix_ext(1,1) == 1000) then
!!$                iteration = iteration+1
!!$                call int2string(iteration, id_text)
!!$                open(58,file='p'//id_text//'.dat')
!!$                do i = 1, 10000
!!$                   par = fg_components(comp)%priors(p_local,1) + &
!!$                        & (fg_components(comp)%priors(p_local,2)-fg_components(comp)%priors(p_local,1)) * &
!!$                        & (i-1.d0)/(10000.d0-1.d0)
!!$                   write(58,*) par, lnL_specind_ARS(par)
!!$                end do
!!$                close(58)
!!$                !call mpi_finalize(ierr)
!!$                !stop
!!$             end if

             !if (present(chisq_out)) chisq_out = -2.d0*lnL_specind_ARS(0.683d0)
          else
             
             write(*,*) 'Warning: Spectral index sampling failed'
!!$    if (myid_chain == root) then
!!$       open(58,file='ind.dat')
!!$       do i = 1, 10000
!!$          if (mod(i,100) ==0) write(*,*) 'i = ', i
!!$          par = sample_ARS(handle, lnL_specind_ARS, x_init, fg_components(comp)%priors(p_local,1:2,s), status)
!!$          write(58,*) i, par
!!$       end do
!!$       close(58)
 
             !call int2string(myid_chain, id_text)
             iteration = iteration+1
             call int2string(iteration, id_text)
             open(58,file='data'//id_text//'.dat')
             write(*,*) 'npix_reg = ', region%n
             do j = 1, region%n
                write(58,*) '# ', region%pix(j,:), comp, p_local
                do i = 1, numband
                   if (invN_reg(j,i) > 0.d0) then
                      write(58,*) real(bp(i)%nu_c,sp), real(d_reg(j,i),sp), real(sqrt(1.d0/invN_reg(j,i)),sp)
                   end if
                end do
                write(58,*)
             end do
             close(58)
             open(58,file='p'//id_text//'.dat')
             do i = 1, 1000
                par = fg_components(comp)%priors(p_local,1) + &
                     & (fg_components(comp)%priors(p_local,2)-fg_components(comp)%priors(p_local,1)) * &
                     & (i-1.d0)/(1000.d0-1.d0)
                write(58,*) par, lnL_specind_ARS(par)
             end do
             close(58)
             call mpi_finalize(ierr)
             stop
             
             
          end if
       end if
       stat = 0
       
       if (present(chisq_out)) chisq_out = -2.d0*lnL_specind_ARS(par)
       chisq = -2.d0*lnL_specind_ARS(par)

!!$       if (chisq > 1d12) then
!!$          write(*,*)
!!$          write(*,*) comp, p, real(chisq0,sp), real(chisq,sp)
!!$          write(*,*) 'foer  = ', real(par_old,sp)
!!$          write(*,*) 'etter = ', real(par,sp)
!!$
!!$             call int2string(pix_reg(1,1), id_text)
!!$             open(58,file='data'//id_text//'.dat')
!!$             write(*,*) 'npix_reg = ', region%n
!!$             do j = 1, region%n
!!$                write(58,*) '# ', region%pix(j,:), comp, p_local
!!$                do i = 1, numband
!!$                   if (invN_reg(j,i) > 0.d0) then
!!$                      write(58,*) real(bp(i)%nu_c,sp), real(d_reg(j,i),sp), real(sqrt(1.d0/invN_reg(j,i)),sp)
!!$                   end if
!!$                end do
!!$                write(58,*)
!!$             end do
!!$             close(58)
!!$
!!$          call int2string(pix_reg(1,1), id_text)
!!$          open(58,file='p'//id_text//'.dat')
!!$          do i = 1, 1000
!!$             p_test = fg_components(comp)%priors(p_local,1) + &
!!$                  & (fg_components(comp)%priors(p_local,2)-fg_components(comp)%priors(p_local,1)) * &
!!$                  & (i-1.d0)/(1000.d0-1.d0)
!!$             chisq0 = lnL_specind_ARS(p_test)
!!$             write(58,*) p_test, chisq0
!!$          end do
!!$          close(58)
!!$
!!$          stop
!!$       end if

       ! Update recent points list
       if (first_call .and. .false.) then
          call QuickSort_dp_dist(x_n, S_n)
          do i = 1, min(size(region%recent), size(x_n))
             region%recent(i) = x_n(size(x_n)-i+1)
          end do
       else
          region%recent(1:num_recent_point-1) = region%recent(2:num_recent_point)
          region%recent(num_recent_point)     = par
       end if
       
!    if (fg_components(comp)%indlabel(p_local) == 'F217' .or. fg_components(comp)%indlabel(p_local) == 'F353' &
!         & .or. fg_components(comp)%indlabel(p_local) == 'F545' .or. &
!         & fg_components(comp)%indlabel(p_local) == 'F857') then
    !if (trim(fg_components(comp)%indlabel(p_local)) == 'nup' .and. npix_reg > 1000 .and. .false.) then
    !if (.false. .and. myid_chain == root) then
    !write(*,*) 'hei', par
       if (.false.) then
          !write(*,*) 'hei', par
          open(79,file=trim(fg_components(comp)%indlabel(p_local)) //'_out.dat')
          do i = 1, 1000
             par = fg_components(comp)%priors(p_local,1) + &
                  & (fg_components(comp)%priors(p_local,2)-fg_components(comp)%priors(p_local,1)) * &
                  & (i-1.d0)/(1000.d0-1.d0)
             write(79,*) par, -2.d0*lnL_specind_ARS(par)
             !       write(*,*) par, -2.d0*lnL_specind_ARS(par)
          end do
          close(79)
          !write(*,*) 'etter'
       end if
       !call mpi_finalize(ierr)
       !stop
    end if

    if (allocated(x_n)) deallocate(x_n)
    if (allocated(S_n)) deallocate(S_n)    
    deallocate(d_reg, amp_reg, invN_reg, fg_par_reg, s_reg, w_reg, pix_reg, inc_band)

  end subroutine sample_spec_index_single_region

  ! The following subroutine is written in order to sample the velocity map of a (several) CO_velocity component(s)
  ! It is not working as of 10.03.2021, but it is being worked on!
  subroutine sample_CO_velocity_map(s0, residuals_in, inv_N_in, fg_amp_in, fg_param_map, co_group, stat)
    implicit none
    
    type(genvec),                     intent(in),    optional :: s0
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: residuals_in, fg_amp_in
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: inv_N_in
    real(dp), dimension(0:,1:,1:),    intent(inout), optional :: fg_param_map
    integer(i4b),                     intent(inout), optional :: stat
    integer(i4b),                     intent(in),    optional :: co_group

    integer(i4b) :: i, j, k, l, m, n, p, q, r, s, fac, mystat, pix, c, test
    integer(i4b) :: num_CO_comp, num_CO_tilt, ref_band, band, id, vmap_group
    integer(i4b) :: CO_tilt_bands(num_fg_par), CO_comps(num_fg_comp),tilt_id(num_fg_par)
    logical(lgt) :: accept, include_CO_band(numband), band_counted(numband)
    logical(lgt) :: update_vmap_comp(num_fg_comp)
    real(dp)     :: chisq_prop, chisq0, chisq0_rms, chisq_prop_rms, accept_prob
    real(dp)     :: vmap_gauss(2), vmap_uni(2), chisq_in, chisq_out, speed_of_light
    real(dp)     :: A, b, mu, sigma, par, scale, sigma_p, tilt, nu_ref
    real(dp), allocatable, dimension(:,:,:)   :: par_prop, par0, par_smooth
    real(dp), allocatable, dimension(:,:,:)   :: residuals, fg_amp
    real(dp), allocatable, dimension(:,:,:)   :: inv_N
    real(dp), allocatable, dimension(:,:)     :: chisq_map, vmap0, vmap_p
    real(dp), allocatable, dimension(:,:)     :: vmap_temp, res_temp
    real(dp), allocatable, dimension(:), save :: N_accept, N_total

    vmap_uni(1)  = 3000.d0 !not physical with velocities larger than 3000 km/s)
    vmap_uni(2) = -3000.d0 ! AND! we sample frequency shift --> neg vel => positive shift
      
    speed_of_light = 2.99792458d8 !m/s
    
    mystat = 0
    if (myid_chain == root) vmap_group = co_group
    call mpi_bcast(vmap_group, 1, MPI_INTEGER, root, comm_chain, ierr)

    !Start by finding how many CO_velocity components and tilt parameters we've got
    if (myid_chain == root .and. verbosity > 2) then
       write(*,*) '   Hardcoded limits: velocity min [km/s] =',vmap_uni(2)
       write(*,*) '                     velocity max [km/s] =',vmap_uni(1)
    end if
    ! need to get velocity in terms of frequency shift
    vmap_uni = sqrt( (1.d0-vmap_uni/(speed_of_light/1.d3))/ &
         & (1.d0+vmap_uni/(speed_of_light/1.d3)) ) - 1.d0
    if (myid_chain == root .and. verbosity > 2) then
       write(*,*) '                relative freq. shift min =',vmap_uni(1)
       write(*,*) '                relative freq. shift max =',vmap_uni(2)
    end if

    num_CO_comp = 0
    num_CO_tilt = 0
    include_CO_band = .false.
    l=0

    update_vmap_comp = .false.
    do i = 1, num_fg_comp
       if (trim(fg_components(i)%type) == 'CO_velocity') then
          if (fg_components(i)%vmap_group == vmap_group) then !get the components to update
             update_vmap_comp(i)=.true.             
             if (fg_components(i)%sample_vmap == .true.) then !get the components to sample
                if (myid_chain == root .and. verbosity > 1) then
                   write(*,*) '       using CO component: ', fg_components(i)%label
                end if
                num_CO_comp = num_CO_comp + 1
                CO_comps(num_CO_comp) = i
                do k = 1,fg_components(i)%nharm + 1
                   num_CO_tilt = num_CO_tilt + 1
                   tilt_id(num_CO_tilt)=l+fg_components(i)%nharm+k !get index in fg_param_map
                   CO_tilt_bands(num_CO_tilt)=fg_components(i)%co_band(k)
                   include_CO_band(fg_components(i)%co_band(k)) = .true.
                end do
             end if
          end if
       end if
       l = l + fg_components(i)%npar
    end do

    ! If there are no CO_velocity components to sample from or the rms is equal to 0 
    ! then there are no need to sample
    if (num_CO_comp == 0) return
    ! check the first rms, they share same rms from initialization
    if (fg_components(CO_comps(1))%vmap_rms == 0.d0) return 
    vmap_gauss(2) = fg_components(CO_comps(1))%vmap_rms
    if (myid_chain == root .and. verbosity > 2) write(*,*) '          Preparing maps'
   
    ! read-in of important parameter maps
    allocate(vmap0(0:npix-1,1), vmap_p(0:npix-1,1),vmap_temp(0:npix-1,1))

    allocate(par_prop(0:npix-1,nmaps,num_fg_par), par0(0:npix-1,nmaps,num_fg_par))
    allocate(par_smooth(0:npix-1,nmaps,num_fg_par))
    if (myid_chain == root) par0 = fg_param_map
    call mpi_bcast(par0, size(par0), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call get_smooth_par_map(par0, par_smooth)


    ! Distribute information
    allocate(residuals(0:npix-1,nmaps,numband), res_temp(0:npix-1,numband))
    allocate(inv_N(0:npix-1,nmaps,numband))
    allocate(fg_amp(0:npix-1,nmaps,num_fg_comp))
    
    if (myid_chain == root) then
       residuals = residuals_in
       inv_N     = inv_N_in
       fg_amp    = fg_amp_in
       vmap0     = fg_components(CO_comps(1))%vmap
       vmap_p    = fg_components(CO_comps(1))%vmap_prior
    end if
    
    call mpi_bcast(residuals, size(residuals), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(inv_N,     size(inv_N),     MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(fg_amp,    size(fg_amp),    MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(vmap0,     size(vmap0),     MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(vmap_p,    size(vmap_p),    MPI_DOUBLE_PRECISION, root, comm_chain, ierr)

    vmap_temp = vmap0

    ! Now we want to set up the residuals of each CO tilt parameter. 
    ! The easiest way of doing this is to compute the full residual map of each band,
    ! and then add the contribution of the given tilt to the relevant resudual.
    ! We only care about creating residuals of bands that are a part of CO_velocity comps.

    ! s = polarization = 1 as CO is only itensity, not polarization
    s=1
    allocate(fg_par_reg(0:npix-1))
    if (myid_chain == root .and. verbosity > 2) write(*,*) '          Creating residuals'
    do pix = 0,npix-1
       call reorder_fg_params(par_smooth(pix,:,:), fg_par_reg(pix))
       do k = 1,numband
          if (include_CO_band(k)) then
             do j = 1,num_fg_comp
                residuals(pix,s,k) = residuals(pix,s,k) - &
                     & get_effective_fg_spectrum(fg_components(j), k, &
                     & fg_par_reg(pix)%comp(j)%p(s,:), pixel=pix, pol=s) * fg_amp(pix,s,j) 
             end do
          end if
       end do
    end do


    ! Now we have reduced all residuals (i.e. data in spectral index sampling) to
    ! the real residual maps. Now we start sampling the vmap.

    ! calculate chisq in
    allocate(chisq_map(0:npix-1,numband))
    chisq_map = 0.d0
    band_counted=.false.

    do j = 1, num_CO_comp
       id=CO_comps(j)
       do i = 1,fg_components(id)%nharm+1
          band=fg_components(id)%co_band(i)
          if (band_counted(band) == .false.) then !reduce identical chisq calculations
             chisq_map(:,band) =  residuals(:,s,band)*inv_N(pix,s,band)*residuals(:,s,band)
             band_counted(band) = .true.
          end if
       end do
    end do
    chisq_in = sum(sum(chisq_map(:,:), dim=1),dim=1)
    if (myid_chain == root .and. verbosity > 0) write(*,*) '    Chisq in =', chisq_in


    if (myid_chain == root .and. verbosity > 2) write(*,*) '          Sampling vmap'
    do pix = 0, npix-1
       vmap_gauss(1)=vmap_p(pix,1) !set prior value
!       if (verbosity > 2 .and. mod(pix,10000)) then 
!          write(*,*) '              Pixel', pix,'of',npix
!       end if
       ! Compute likelihood term
       A     = 0.d0
       b     = 0.d0
       l = 0
       if (myid_chain==root  .and. pix==0) write(*,*) 'comp id, tilt nr (ref=1), tilt_id (fg_par_map)'
       do j = 1, num_CO_comp
          id=CO_comps(j)
          ref_band=fg_components(id)%co_band(1)
          nu_ref=fg_components(id)%nu_ref
          do i = 1,fg_components(id)%nharm+1
             l = l + 1
             band=fg_components(id)%co_band(i)
             tilt=par0(pix,s,tilt_id(l))
             ! band for tilt i is co_band(i)
             !!! DEBUG !!!
             if (myid_chain==root .and. pix==0) write(*,*) id, l, tilt_id(l)
             scale = (bp(band)%co2t/bp(band)%a2t) / (bp(ref_band)%co2t/bp(ref_band)%a2t) * &
                  &  bp(band)%gain * ant2data(band)
             
             A = A + scale*fg_amp(pix,s,id)*nu_ref*tilt/1.d9 * inv_N(pix,s,band) * & 
                  & scale*fg_amp(pix,s,id)*nu_ref*tilt/1.d9
             b = b + scale*fg_amp(pix,s,id)*nu_ref*tilt/1.d9 * inv_N(pix,s,band) * &
                  & (residuals(pix,s,band) + scale*fg_amp(pix,s,id)*vmap0(pix,1)* &
                  & nu_ref*tilt/1.d9 ) 
          end do
       end do

       !!! DEBUG !!!


       if (A > 0.d0) then
          mu    = b / A
          sigma = sqrt(1.d0 / A)
       else if (vmap_gauss(2) > 0.d0) then
          mu    = 0.d0
          sigma = 1.d30
       else
          mu    = vmap_uni(1) + (vmap_uni(2)-vmap_uni(1))*rand_uni(handle)
          sigma = 0.d0
       end if

       ! Add prior
       if (vmap_gauss(2) > 0.d0) then
          sigma_p = vmap_gauss(2) ! equal to the rms as we dont have more than 1 pixel
          mu      = (mu*sigma_p**2 + vmap_gauss(1) * sigma**2) / (sigma_p**2 + sigma**2)
          sigma   = sqrt(sigma**2 * sigma_p**2 / (sigma**2 + sigma_p**2))
       end if

       ! Draw sample
       par = -1.6375d30
       if (trim(operation) == 'optimize') then
          if (mu < vmap_uni(1)) then
             par = vmap_uni(1)
          else if (mu > vmap_uni(2)) then
             par = vmap_uni(2)
          else
             par = mu
          end if
       else
          do while (par < vmap_uni(1) .or. par > vmap_uni(2))
             if (mu < vmap_uni(1)) then
                par = rand_trunc_gauss(handle, mu, vmap_uni(1), sigma)
             else if (mu > vmap_uni(2)) then
                par = 2.d0*mu-rand_trunc_gauss(handle, mu, 2.d0*mu-vmap_uni(2), sigma)
             else
                par = mu + sigma * rand_gauss(handle)
             end if
          end do
       end if

       vmap_temp(pix,1)=par

    end do

    ! check new chisq values
    !first calculate the new residuals (using new and old velocities), then calc. chisq
    res_temp(:,:) = residuals(:,s,:)
    do pix = 0, npix-1
       l = 0
       do j = 1, num_CO_comp
          id=CO_comps(j)
          ref_band=fg_components(id)%co_band(1)
          nu_ref=fg_components(id)%nu_ref
          do i = 1,fg_components(id)%nharm+1
             l = l + 1
             band=fg_components(id)%co_band(i)
             tilt=par0(pix,s,tilt_id(l))
             scale = (bp(band)%co2t/bp(band)%a2t) / (bp(ref_band)%co2t/bp(ref_band)%a2t) * &
                  &  bp(band)%gain * ant2data(band)
             res_temp(pix,band) = res_temp(pix,band) + scale*fg_amp(pix,s,id)* &
                  & ( vmap0(pix,1) - vmap_temp(pix,1) ) * nu_ref*tilt/1.d9  
          end do
       end do
    end do

    chisq_map = 0.d0
    band_counted=.false.

    do j = 1, num_CO_comp
       id=CO_comps(j)
       do i = 1,fg_components(id)%nharm+1
          band=fg_components(id)%co_band(i)
          if (band_counted(band) == .false.) then !reduce identical chisq calculations
             chisq_map(:,band) =  res_temp(:,band)*inv_N(:,s,band)*res_temp(:,band)
             band_counted(band) = .true.
          end if
       end do
    end do
    chisq_out = sum(sum(chisq_map(:,:), dim=1),dim=1)
    if (myid_chain == root .and. verbosity > 0) write(*,*) '    Chisq out =', chisq_out


    if (chisq_out < chisq_in) then
       if (myid_chain == root .and. verbosity > 2) write(*,*) '       Updating component vmaps'    
       !update component velocity maps for the components in the group
       do j =1,num_fg_comp
          if (update_vmap_comp(j)) fg_components(j)%vmap = vmap_temp
       end do
    else
       if (myid_chain == root .and. verbosity > 2) write(*,*) '       Chisq_out > Chisq_in'
       if (myid_chain == root .and. verbosity > 2) write(*,*) '       Not updating vmaps. BUG!'    
    end if

    !#############################################################################!

    call mpi_reduce(mystat, i, 1, MPI_INTEGER, MPI_SUM, root, comm_chain, ierr)
    if (myid_chain == root) then
       fg_param_map = par0
       stat         = i
    end if

    deallocate(par0, par_prop, par_smooth)
    deallocate(residuals, vmap0, vmap_p, vmap_temp)
    deallocate(inv_N, chisq_map, res_temp)
    deallocate(fg_amp, fg_par_reg)

  end subroutine sample_CO_velocity_map

  function neg_lnL_specind_ARS(p)
    use healpix_types
    implicit none
    real(dp), dimension(:), intent(in), optional :: p
    real(dp)                           :: neg_lnL_specind_ARS
    if (p(1) < fg_components(comp_reg)%priors(p_local_reg,1) .or. &
         & p(1) > fg_components(comp_reg)%priors(p_local_reg,2)) then
       neg_lnL_specind_ARS = 1.d30
    else
       neg_lnL_specind_ARS = -lnL_specind_ARS(p(1))
    end if
  end function neg_lnL_specind_ARS


  function lnL_specind_ARS(x)
    use healpix_types
    implicit none
    real(dp), intent(in) :: x
    real(dp)             :: lnL_specind_ARS

    integer(i4b) :: i, j, n
    real(dp)     :: lnL, f, lnL_jeffreys, lnL_gauss, par(30)
    logical(lgt) :: jeffreys
    real(dp), allocatable, dimension(:,:) :: df

    if (x < fg_components(comp_reg)%priors(p_local_reg,1) .or. &
         & x > fg_components(comp_reg)%priors(p_local_reg,2)) then
       lnL_specind_ARS = 1.d30
       return
    end if
    
    jeffreys = fg_components(comp_reg)%apply_jeffreys_prior
    n        = fg_components(comp_reg)%npar

    ! Compute chi-square term
    allocate(df(npix_reg,numband))
    lnL      = 0.d0
    do i = 1, npix_reg
       par(1:n) = fg_par_reg(i)%comp(comp_reg)%p(s_reg(i),1:n)
       par(p_local_reg) = max(min(par(p_local_reg) + w_reg(i) * (x-par_old), P_uni_reg(2)), &
            & P_uni_reg(1))
!       par(p_local_reg) = max(min(x, P_uni_reg(2)), P_uni_reg(1))
       do j = 1, numband
          if (.not. inc_band(j)) cycle
          f = d_reg(i,j) - amp_reg(i) * get_effective_fg_spectrum(fg_components(comp_reg), &
               & j, par(1:n), pixel=pix_reg(i,1), pol=pix_reg(i,2))
          lnL = lnL - 0.5d0 * f * invN_reg(i,j) * f
          if (jeffreys) then
             df(i,j) = -amp_reg(i) * get_effective_deriv_fg_spectrum(fg_components(comp_reg), &
                  & j, p_local_reg, par(1:n), pixel=pix_reg(i,1), pol=pix_reg(i,2)) * w_reg(i)
          end if
          !write(*,*) i, j, lnL
          !write(*,*) 'a', real(f,sp), real(amp_reg(i),sp), real(par(1:n),sp)
!!$          if (pix_reg(i,1) == 22946) then
!             write(*,fmt='(i6,7e16.8)') j, x, par(p_local_reg), d_reg(i,j), amp_reg(i), &
!                  & get_effective_fg_spectrum(fg_components(comp_reg), &
!x                  & j, par(1:n), pixel=pix_reg(i,1), pol=pix_reg(i,2)), w_reg(i), lnL
!!$          end if
       end do
    end do
!!$    if (x == 0.683d0) then
!!$       write(*,*) 'lnL(0.683) = ', lnL
!!$    end if


    ! Compute Jeffreys prior
    if (.false. .and. jeffreys) then
       lnL_jeffreys = log(sqrt(sum(df * invN_reg * df)))
    else
       lnL_jeffreys = 0.d0
    end if

    ! Compute Gaussian prior
    if (P_gauss_reg(2) > 0.d0) then
       lnL_gauss = -0.5d0*((x-P_gauss_reg(1))/P_gauss_reg(2))**2
    else
       lnL_gauss = 0.d0
    end if

    ! Return result
    lnL_specind_ARS = lnL + lnL_jeffreys + lnL_gauss

!!$    if (pix_reg(1,1) == 22946) then
!!$       write(*,fmt='(a,3e16.8)') 'lnL = ', lnL, lnL_jeffreys, lnL_gauss
!!$    end if

    !write(*,*) real(x,sp), real(lnL,sp), real(lnL_jeffreys,sp), real(lnL_gauss,sp)
    !lnL_specind_ARS = lnL_jeffreys 

    deallocate(df)

  end function lnL_specind_ARS

  function sample_CO_line(id, band)  
    implicit none

    integer(i4b), intent(in) :: id, band
    real(dp)                 :: sample_CO_line

    integer(i4b) :: i, ref_band
    real(dp)     :: A, b, mu, sigma, par, scale, sigma_p

    !sampler the line ratio for the CO multiline component

    ref_band = fg_components(id)%co_band(1)

    ! Compute likelihood term
    A     = 0.d0
    B     = 0.d0
    scale = (bp(band)%co2t/bp(band)%a2t) / (bp(ref_band)%co2t/bp(ref_band)%a2t) * &
         &  bp(band)%gain * ant2data(band)
    do i = 1, npix_reg
       A = A + scale*amp_reg(i) * invN_reg(i,band) * scale*amp_reg(i)
       b = b + scale*amp_reg(i) * invN_reg(i,band) * d_reg(i,band)
    end do
    if (A > 0.d0) then
       mu    = b / A
       sigma = sqrt(1.d0 / A)
    else if (P_gauss_reg(2) > 0.d0) then
       mu    = 0.d0
       sigma = 1.d30
    else
       mu    = P_uni_reg(1) + (P_uni_reg(2)-P_uni_reg(1))*rand_uni(handle)
       sigma = 0.d0
    end if

    ! Add prior
    if (P_gauss_reg(2) > 0.d0) then
       sigma_p = P_gauss_reg(2) / sqrt(real(npix_reg,dp))
       mu      = (mu*sigma_p**2 + P_gauss_reg(1) * sigma**2) / (sigma_p**2 + sigma**2)
       sigma   = sqrt(sigma**2 * sigma_p**2 / (sigma**2 + sigma_p**2))
    end if

    ! Draw sample
    par = -1.d30
    if (trim(operation) == 'optimize') then
       if (mu < P_uni_reg(1)) then
          par = P_uni_reg(1)
       else if (mu > P_uni_reg(2)) then
          par = P_uni_reg(2)
       else
          par = mu
       end if
    else
       do while (par < P_uni_reg(1) .or. par > P_uni_reg(2))
          if (mu < P_uni_reg(1)) then
             par = rand_trunc_gauss(handle, mu, P_uni_reg(1), sigma)
          else if (mu > P_uni_reg(2)) then
             par = 2.d0*mu-rand_trunc_gauss(handle, mu, 2.d0*mu-P_uni_reg(2), sigma)
          else
             par = mu + sigma * rand_gauss(handle)
          end if
       end do
    end if
    sample_CO_line = par

  end function sample_CO_line

  function sample_CO_lr_velocity(id, band, tilt, harm, nu_ref)  
    implicit none

    integer(i4b), intent(in) :: id, band, harm
    real(dp), intent(in)     :: tilt, nu_ref
    real(dp)                 :: sample_CO_lr_velocity

    integer(i4b) :: i, ref_band
    real(dp)     :: A, b, mu, sigma, par, scale, sigma_p

    ! id (integer): parameter id (to get the correct component)
    !
    ! band (integer): band number for the corresponding data band of the sampled parameter (co_band(p_local))
    !
    ! tilt (real dp): bandpass tilt (in same units of LR and per GHz) 
    !
    ! harm (integer): local parameter index (harmonic) for the parameter to be sampled
    !
    ! nu_ref (real dp): reference frequency of the component (in Hz)

    ref_band = fg_components(id)%co_band(1)

    ! Compute likelihood term
    ! computed similar to the CO multiline component
    A     = 0.d0
    b     = 0.d0
    scale = (bp(band)%co2t/bp(band)%a2t) / (bp(ref_band)%co2t/bp(ref_band)%a2t) * &
         &  bp(band)%gain * ant2data(band)
    do i = 1, npix_reg
       A = A + scale*amp_reg(i) * invN_reg(i,band) * scale*amp_reg(i)
       b = b + scale*amp_reg(i) * invN_reg(i,band) * (d_reg(i,band) - & 
            & scale*amp_reg(i)*vmap_reg(i)*nu_ref*tilt/1.d9 ) 
       ! reduced data (i.e. d_reg) = data - all other components
       ! One needs to also subtract the CO signal due to bandpass tilt and 
       ! Doppler shift in frequency from the CO-clouds' radial velocity
       ! vmap_reg is relativ frequency shift (w.r.t. nu_ref), and tilt is per GHz (nu_ref in Hz)
    end do

    if (A > 0.d0) then
       mu    = b / A
       sigma = sqrt(1.d0 / A)
    else if (P_gauss_reg(2) > 0.d0) then
       mu    = 0.d0
       sigma = 1.d30
    else
       mu    = P_uni_reg(1) + (P_uni_reg(2)-P_uni_reg(1))*rand_uni(handle)
       sigma = 0.d0
    end if

    ! Add prior
    if (P_gauss_reg(2) > 0.d0) then
       sigma_p = P_gauss_reg(2) / sqrt(real(npix_reg,dp))
       mu      = (mu*sigma_p**2 + P_gauss_reg(1) * sigma**2) / (sigma_p**2 + sigma**2)
       sigma   = sqrt(sigma**2 * sigma_p**2 / (sigma**2 + sigma_p**2))
    end if

    ! Draw sample
    par = -1.d30
    if (trim(operation) == 'optimize') then
       if (mu < P_uni_reg(1)) then
          par = P_uni_reg(1)
       else if (mu > P_uni_reg(2)) then
          par = P_uni_reg(2)
       else
          par = mu
       end if
    else
       do while (par < P_uni_reg(1) .or. par > P_uni_reg(2))
          if (mu < P_uni_reg(1)) then
             par = rand_trunc_gauss(handle, mu, P_uni_reg(1), sigma)
          else if (mu > P_uni_reg(2)) then
             par = 2.d0*mu-rand_trunc_gauss(handle, mu, 2.d0*mu-P_uni_reg(2), sigma)
          else
             par = mu + sigma * rand_gauss(handle)
          end if
       end do
    end if

    sample_CO_lr_velocity = par

  end function sample_CO_lr_velocity


  function sample_CO_tilt_velocity(id, band, lr_in, locpar, nu_ref)  
    implicit none

    integer(i4b), intent(in) :: id, band, locpar
    real(dp), intent(in)     :: lr_in, nu_ref
    real(dp)                 :: sample_CO_tilt_velocity

    integer(i4b) :: i, ref_band
    real(dp)     :: A, b, mu, sigma, par, scale, sigma_p, lr

    ! id (integer): parameter id (to get the correct parameter
    !
    ! band (integer): band number for the corresponding data band of the tilt parameter (co_band(p_local-nharm))
    !
    ! lr_in (real dp): line ratio of the given band
    !
    ! locpar (integer): local parameter index for the parameter to be sampled
    !
    ! nu_ref (real dp): reference frequency of the component (in Hz)

    ref_band = fg_components(id)%co_band(1)

    ! assigning correct line ratio when calculating the tilt of the reference band
    lr = lr_in
    if (locpar == fg_components(id)%nharm+1) lr = 1.d0 ! if reference band tilt, line ratio = 1.d0 (tilt was given)

    ! Compute likelihood term
    ! computed similar to the CO multiline component
    A     = 0.d0
    b     = 0.d0
    scale = (bp(band)%co2t/bp(band)%a2t) / (bp(ref_band)%co2t/bp(ref_band)%a2t) * &
         &  bp(band)%gain * ant2data(band)
    do i = 1, npix_reg
       A = A + scale*(amp_reg(i)*vmap_reg(i)*nu_ref/1.d9) * invN_reg(i,band) * &
            & scale*(amp_reg(i)*vmap_reg(i)*nu_ref/1.d9)
       !usually for line ratio one has d_reg=amp_reg*LR + noise
       !here we have d_reg=amp_reg*nu_shift*tilt, so amp_reg has to become amp_reg*nu_shift
       ! nu_shift (in units of GHz^-1) is vmap_reg/1.d9, as vmap_reg is in Hz
       b = b + scale*(amp_reg(i)*vmap_reg(i)*nu_ref/1.d9) * invN_reg(i,band) * &
            & (d_reg(i,band) - scale*amp_reg(i)*lr ) 
       !reduced data (i.e. d_reg) = data - all other components
       ! One needs to also subtract the CO without tilt (i.e. subtract the line ratio contribution) 
       !in order to only fit the tilt. 
    end do

    if (A > 0.d0) then
       mu    = b / A
       sigma = sqrt(1.d0 / A)
    else if (P_gauss_reg(2) > 0.d0) then
       mu    = 0.d0
       sigma = 1.d30
    else
       mu    = P_uni_reg(1) + (P_uni_reg(2)-P_uni_reg(1))*rand_uni(handle)
       sigma = 0.d0
    end if


    ! Add prior if the prior RMS > 0
    if (P_gauss_reg(2) > 0.d0) then
       write(*,*) "pre-prior:  p_local =",locpar,"mu =", mu,"sigma =",sigma
       sigma_p = P_gauss_reg(2) / sqrt(real(npix_reg,dp))
       mu      = (mu*sigma_p**2 + P_gauss_reg(1) * sigma**2) / (sigma_p**2 + sigma**2)
       sigma   = sqrt(sigma**2 * sigma_p**2 / (sigma**2 + sigma_p**2))
       write(*,*) "post-prior: p_local =",locpar,"mu =", mu,"sigma =",sigma
    end if



    ! Draw sample
    par = -1.d30
    if (trim(operation) == 'optimize') then
       if (mu < P_uni_reg(1)) then
          par = P_uni_reg(1)
       else if (mu > P_uni_reg(2)) then
          par = P_uni_reg(2)
       else
          par = mu
       end if
    else
       do while (par < P_uni_reg(1) .or. par > P_uni_reg(2))
          if (mu < P_uni_reg(1)) then
             par = rand_trunc_gauss(handle, mu, P_uni_reg(1), sigma)
          else if (mu > P_uni_reg(2)) then
             par = 2.d0*mu-rand_trunc_gauss(handle, mu, 2.d0*mu-P_uni_reg(2), sigma)
          else
             par = mu + sigma * rand_gauss(handle)
          end if
       end do
    end if


    sample_CO_tilt_velocity = par

  end function sample_CO_tilt_velocity

  subroutine init_ind(residuals_in, inv_N_in, index_map, fg_amp)
    implicit none

    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: residuals_in
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: inv_N_in
    real(dp), dimension(0:,1:,1:),    intent(inout), optional :: index_map, fg_amp

    integer(i4b) :: i, j, k, l, p, q, fac, n, ierr, CO_ind, npar, nsamp, accept, counter
    real(dp)     :: x_min, x_max, y_min, y_max, chisq, s, lnL, lnL_prop, chisq_prop, chisq0, chisq1
    logical(lgt) :: converged 
    character(len=4) :: chain_text
    real(dp), allocatable, dimension(:,:,:)   :: my_fg_param_map
    real(dp), allocatable, dimension(:,:,:)   :: residuals, ind_map, buffer, my_fg_amp
    real(dp), allocatable, dimension(:,:,:,:) :: inv_N
    real(dp), allocatable, dimension(:)       :: r1, r2, x, b, x_prop
    real(dp), allocatable, dimension(:,:)     :: chisq_tot, my_chisq, samples, M, A, outmap
    type(fg_params)     :: fg_par

    ! Distribute information
    allocate(all_residuals(0:npix-1,numband))
    allocate(all_inv_N(0:npix-1,numband))
    allocate(my_fg_amp(0:npix-1,1,num_fg_comp))
    allocate(x_def(num_fg_comp))

    if (myid_chain == root) then
       all_residuals = residuals_in(:,1,:)
       all_inv_N     = inv_N_in(:,1,:)
       my_fg_amp     = fg_amp
       nind          = size(index_map,3)
    end if
    call mpi_bcast(all_residuals, size(all_residuals), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(all_inv_N,     size(all_inv_N),     MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(my_fg_amp,     size(my_fg_amp),     MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(nind,          1,                   MPI_INTEGER,          root, comm_chain, ierr)
    allocate(ind_map(0:npix-1,nmaps,nind))
    if (myid_chain == root) then
       !ind_map = index_map
       call get_smooth_par_map(index_map, ind_map)
    end if
    call mpi_bcast(ind_map,     size(ind_map),     MPI_DOUBLE_PRECISION, root, comm_chain, ierr)

    namp = 0
    ! NEW
    do i = 1, num_fg_comp
       if (trim(fg_components(i)%type) /= 'freefree_EM' .and. & 
            & fg_components(i)%sample_amplitudes) namp = namp+1
    end do

    npar = namp
    do i = 1, num_fg_comp
       do j = 1, fg_components(i)%npar
          if (fg_components(i)%gauss_prior(j,2) /= 0.d0 .and. fg_components(i)%indregs(j)%independent_pixels) npar = npar+1
       end do
    end do
    
    allocate(M(numband,num_fg_comp), A(num_fg_comp,num_fg_comp), b(num_fg_comp))
    allocate(my_residual(numband), my_inv_N(numband), p_default(nind))
    allocate(chisq_tot(0:npix-1,1))
    allocate(scale_reg(npar), x(npar), x_prop(npar))

    chisq_tot = 0.d0
    do p = 0, npix-1

       !if (p /= 1000) cycle

!       if (mod(p+myid_chain,numprocs_chain) /= 0 .or. all(all_inv_N(p,:) == 0.d0) .or. p < 335000 .or. p > 336000) then
       if (mod(p+myid_chain,numprocs_chain) /= 0 .or. all(all_inv_N(p,:) == 0.d0)) then
          ind_map(p,:,:) = 0.d0
          my_fg_amp(p,:,:) = 0.d0
          cycle
       end if
       p_default = ind_map(p,1,:)
       pix_init  = p
       s_init    = 1

!       if (mod(p,100) == 0) write(*,*) 'ML initializing pixel no. ', p, ' of ', npix

!!$       ! Compute mixing matrix for this pixel
!!$       call reorder_fg_params(ind_map(p,:,:), fg_par)
!!$       do k = 1, numband
!!$          do j = 1, num_fg_comp
!!$             M(k,j) = get_effective_fg_spectrum(fg_components(j), k, fg_par%comp(j)%p(1,:), pixel=p, pol=1)
!!$          end do
!!$       end do
!!$       call deallocate_fg_params(fg_par)
!!$
!!$       if (all(my_fg_amp(p,1,:) == 0.d0)) then
!!$
!!$          ! Solve GLS equations for amplitude initialization
!!$          A = 0.d0
!!$          b = 0.d0
!!$          do l = 1, numband
!!$             do i = 1, num_fg_comp
!!$                do j = 1, num_fg_comp
!!$                   A(i,j) = A(i,j) + M(l,i) * all_inv_N(p,l) *M(l,j)
!!$                end do
!!$                b(i) = b(i) + M(l,i) * all_inv_N(p,l) * all_residuals(p,l)
!!$             end do
!!$          end do
!!$          call invert_matrix(A)
!!$          b = matmul(A,b)
!!$          x(1:num_fg_comp) = b
!!$          do l = 1, num_fg_comp
!!$             if (fg_components(l)%enforce_positive_amplitude) x(l) = max(b(l), 0.d0)
!!$          end do
!!$       else
!!$          x(1:namp) = amp2x(namp,my_fg_amp(p,1,:))
!!$       end if

       ! Run a non-linear search
       my_residual = all_residuals(p,:)
       my_inv_N    = all_inv_N(p,:)
       N_scale     = 1.d0
!       chisq0 = fg_init_chisq(x)

!!$       if (chisq0 == 1.d30 .or. chisq0 /= chisq0) then
!!$          write(*,*) 'Starting point is invalid ', p, chisq0
!!$          write(*,*) 'x = ', real(x,sp)
!!$          stop
!!$       end if

       chisq     = 1.d30
       converged = .false.
       x_prop    = 0.d0
       
       x_def     = my_fg_amp(p,1,:) ! Saving default amplitude values
       
       !if (myid_chain == 0) then
       !   write(*,*) "x_def", x_def
       !   !write(*,*) "namp", namp, "npar", npar
       !end if
       
       do counter = 1, 100

          if (.true. .or. counter == 1) then
             !if (myid_chain == 0) then
             !   write(*,*) "This goes in ", my_fg_amp(p,1,:)
             !end if
       
             ! Initialize on old solution
             x(1:namp)      = amp2x(namp,my_fg_amp(p,1,:)) ! Save all amplitudes to be sampled here.
             x(namp+1:npar) = par2x(npar-namp,ind_map(p,1,:))
             scale_reg = abs(x)
             where (scale_reg < 1.d-12)
                scale_reg = 1.d0
             end where
             chisq0         = fg_init_chisq(x/scale_reg)
             if (fg_init_chisq(x_prop/scale_reg) < chisq0) x = x_prop
             if (chisq0 == 1.d30 .or. chisq0 /= chisq0) then
                write(*,*) 'Starting point is invalid ', p, chisq0
                write(*,*) 'x = ', real(x,sp)
                stop
             end if
          else 
             ! Draw a random sample over the prior
             x(1:namp) = amp2x(namp,my_fg_amp(p,1,:))
             k = 1
             do i = 1, num_fg_comp
                do j = 1, fg_components(i)%npar
                   if (fg_components(i)%gauss_prior(j,2) /= 0.d0 .and. &
                        & fg_components(i)%indregs(j)%independent_pixels) then
                      x(namp+k) = min(max(fg_components(i)%gauss_prior(j,1) + &
                           & fg_components(i)%gauss_prior(j,2) * rand_gauss(handle), &
                           & fg_components(i)%priors(j,1)), fg_components(i)%priors(j,2))
                      k      = k+1
                   end if
                end do
             end do
          end if

          if (p == -1) then
             chisq = fg_init_chisq(x/scale_reg)
             write(*,*) '-----------------------------------------'
             write(*,*) 'counter   = ', counter
             write(*,*) 'x_in      = ', real(x,sp)
             write(*,*) 'chisq in  = ', chisq
             write(*,*)
          end if

          x = x / scale_reg
          call powell(x, fg_init_chisq, ierr)
          chisq = fg_init_chisq(x)
          x = x * scale_reg
          if (abs(chisq-chisq0) < 1.d0) converged = .true.
!          if (chisq < 3*numband .and. abs(chisq-chisq0) < 20.d0) converged = .true.
          if (chisq < 3*numband) converged = .true.
          if (p == -1) then
             write(*,*) 'x_out     = ', real(x,sp)
             write(*,*) 'chisq_out = ', real(chisq,sp), real(chisq0,sp)
             write(*,*) '-----------------------------------------'
          end if
          if (chisq <= chisq0) then
             chisq0           = chisq
             my_fg_amp(p,1,:) = x2amp(num_fg_comp,x(1:namp))
             !if (myid_chain == 0) then
             !   write(*,*) "This comes out ", my_fg_amp(p,1,:)
             !end if
             ind_map(p,1,:)   = x2par(nind,x(namp+1:npar))
          end if
          if (converged) then
             if (N_scale > 0.75d0) then
                if (mod(p,1000) == 0) write(*,*) 'ML -- p = ', p, ', chisq = ', &
                     & real(chisq,sp), ', niter = ', counter
                exit
             else
                N_scale = 2.d0*N_scale
             end if
          else
             N_scale = 0.5d0*N_scale 
          end if

       end do
       if (counter > 100) then
          write(*,*) 'ML fit failed. Exiting -- pixel = ', p
!          stop
       end if
       x_prop = x

    end do

    allocate(buffer(0:npix-1,nmaps,nind))
    call mpi_reduce(ind_map, buffer, size(buffer), MPI_DOUBLE_PRECISION, MPI_SUM, root, comm_chain, ierr)
    if (myid_chain == root) then
       k = 1
       do i = 1, num_fg_comp
          do j = 1, fg_components(i)%npar
             if (fg_components(i)%fwhm_p(j) == 0.) then 
                do p = 0, npix-1
                   if (any(all_inv_N(p,:) /= 0.d0)) then
                      index_map(p,1,k) = buffer(p,1,k)
                   end if
                end do
             end if
             k = k+1
          end do
       end do
    end if
    deallocate(buffer)

    allocate(buffer(0:npix-1,nmaps,num_fg_comp))
    call mpi_reduce(my_fg_amp, buffer, size(buffer), MPI_DOUBLE_PRECISION, MPI_SUM, root, comm_chain, ierr)
    if (myid_chain == root) then
       do p = 0, npix-1
          if (any(all_inv_N(p,:) /= 0.d0)) then
             fg_amp(p,1,:) = buffer(p,1,:)
             do i = 1, num_fg_comp
                if (fg_components(i)%mask(p,1) < 0.5d0) fg_amp(p,1,i) = 0.d0
             end do
          end if
       end do
    end if
    deallocate(buffer)

!!$    allocate(outmap(0:npix-1,1))
!!$    call mpi_reduce(chisq_tot, outmap, size(outmap), MPI_DOUBLE_PRECISION, MPI_SUM, root, comm_chain, ierr)
!!$    if (myid_chain == root) then
!!$       call write_map('chisq.fits', outmap)       
!!$    end if
!!$    deallocate(outmap, chisq_tot)

!!$    if (myid_chain == root) then
!!$       allocate(outmap(0:npix-1,1))
!!$       outmap = 0.d0
!!$       do p = 0, npix-1
!!$          x(1:namp) = amp2x(namp,fg_amp(p,1,:))
!!$          x(namp+1:npar) = par2x(npar-namp,index_map(p,1,:))
!!$
!!$          pix_init    = p
!!$          s_init      = 1
!!$          scale_reg   = 1.d0
!!$          p_default   = index_map(p,1,:)
!!$          my_residual = all_residuals(p,:)
!!$          my_inv_N    = all_inv_N(p,:)
!!$          outmap(p,1) = fg_init_chisq(x)
!!$!          write(*,*) p, real(x,sp)
!!$!          write(*,*) p, 'chisq = ', outmap(p,1)
!!$       end do
!!$       call write_map('chisq2.fits', outmap)       
!!$       write(*,*) 'chisq etter = ', sum(outmap)       
!!$       write(*,*) 'chisq pix = ', outmap(25729,1)
!!$       write(*,*) 'amp = ', fg_amp(25729,1,:)
!!$       write(*,*) 'ind = ', index_map(25729,1,:)
!!$
!!$       deallocate(outmap)
!!$       
!!$    end if

    deallocate(A, x, x_prop, b, M, all_inv_N, all_residuals, my_residual, my_inv_N, scale_reg)
    deallocate(my_fg_amp, ind_map, p_default)
    deallocate(x_def)
!!$    call mpi_finalize(ierr)
!!$    stop

  end subroutine init_ind

  function par2x(n,p) result (res)
    implicit none

    integer(i4b),                intent(in)  :: n
    real(dp),     dimension(1:), intent(in)  :: p
    real(dp),     dimension(n)               :: res

    integer(i4b) :: i, j, k, l

    k = 1
    l = 1
    do i = 1, num_fg_comp
       do j = 1, fg_components(i)%npar
          if (fg_components(i)%gauss_prior(j,2) /= 0.d0 .and. fg_components(i)%indregs(j)%independent_pixels) then
             res(k) = p(l)
             k      = k+1
          end if
          l = l+1
       end do
    end do

  end function par2x

  function amp2x(n,p) result (res)
    implicit none

    integer(i4b),                intent(in)  :: n
    real(dp),     dimension(1:), intent(in)  :: p
    real(dp),     dimension(n)               :: res

    integer(i4b) :: i, j, k, l
    ! NEW 
    k = 1
    ! Putting amplitude into sampling array. Do not put amplitudes that are not supposed to be sampled in.
    do i = 1, num_fg_comp
       if (trim(fg_components(i)%type) /= 'freefree_EM' .and. fg_components(i)%sample_amplitudes) then
          res(k) = p(i)
          k      = k+1
       end if
    end do


  end function amp2x
  
  function x2par(n,x) result (res)
    implicit none

    integer(i4b),                intent(in)  :: n
    real(dp),     dimension(1:), intent(in)  :: x
    real(dp),     dimension(n)               :: res

    integer(i4b) :: i, j, k, l

    k = 1
    l = 1
    do i = 1, num_fg_comp
       do j = 1, fg_components(i)%npar
          if (fg_components(i)%gauss_prior(j,2) /= 0.d0 .and. fg_components(i)%indregs(j)%independent_pixels) then
             res(l) = x(k)
             k      = k+1
          else
             res(l) = p_default(l)
          end if
          l = l+1
       end do
    end do

  end function x2par

  function x2amp(n,x) result (res)
    implicit none

    integer(i4b),                intent(in)  :: n
    real(dp),     dimension(1:), intent(in)  :: x
    real(dp),     dimension(n)               :: res

    integer(i4b) :: i, j, k, l

    k = 1
    ! NEW
    ! Fetch all sampled amplitudes, those that were not sampled, get from prev.

    do i = 1, num_fg_comp
       if (.not. fg_components(i)%sample_amplitudes) then ! Freeze amplitudes
          !if (myid_chain == 0) then
          !   write(*,*) "i", i
          !   write(*,*) "fgcomps sample", fg_components(i)%sample_amplitudes
          !   write(*,*) "comp", fg_components(i)%type
          !   write(*,*) x_def(i)
          !end if
          res(i) = x_def(i) ! Set amplitudes to previous value
          ! x_def has all initial amplitude values stored
          ! Does it contain the right stuff though?
          cycle
       else if (trim(fg_components(i)%type) /= 'freefree_EM') then
          res(i) = x(k)
          k      = k+1
       else
          res(i) = 1.d0
       end if

    end do

  end function x2amp

  function fg_init_chisq(p)
    use healpix_types
    implicit none
    real(dp), dimension(:), intent(in), optional :: p
    real(dp)                           :: fg_init_chisq

    integer(i4b) :: i, j, k, l, npar
    real(dp) :: s, signal, chisq, prior
    real(dp), allocatable, dimension(:) :: fg_amp, fg_ind

    npar = size(p)
    allocate(fg_amp(num_fg_comp), fg_ind(nind))
    ! x2amp(2,p(1:1)*scale_reg(1:1))
    fg_amp = x2amp(num_fg_comp,p(1:namp)*scale_reg(1:namp)) ! p=x here. fg_amp is namp+1
    fg_ind = x2par(nind,p(namp+1:npar)*scale_reg(namp+1:npar))


    !if (myid_chain == 0) then
    !   write(*,*) "p", p, "namp",namp, "p()",p(1:namp)
    !   write(*,*) 'fg_amp = ', fg_amp
       !write(*,*) 'fg_ind = ', real(fg_ind,sp)
    !end if
    
    
    !call mpi_finalize(i)
    !stop
    
    ! Check priors
    do i = 1, num_fg_comp
       if (fg_components(i)%enforce_positive_amplitude .and. fg_amp(i) < 0.d0) then
          fg_init_chisq = 1.d30
          deallocate(fg_amp, fg_ind)
          return
       end if
    end do

    l = 1
    do i = 1, num_fg_comp
       do j = 1, fg_components(i)%npar
          if (fg_ind(l) < fg_components(i)%priors(j,1) .or. fg_ind(l) > fg_components(i)%priors(j,2)) then
             fg_init_chisq = 1.d30
             deallocate(fg_amp, fg_ind)
             return
          end if
          l = l+1
       end do
    end do

    chisq = 0.d0
    do i = 1, numband
       s = 0.d0
       l = 1
       do k = 1, num_fg_comp
          signal = fg_amp(k) * get_effective_fg_spectrum(fg_components(k), i, &
               & fg_ind(l:l+fg_components(k)%npar-1), pixel=pix_init, pol=1)
          s = s + signal
          l = l + fg_components(k)%npar
       end do
       chisq = chisq + (my_residual(i)-s)**2 * (N_scale*my_inv_N(i))
    end do

    l = 1
    prior = 0.d0
    do i = 1, num_fg_comp
       do j = 1, fg_components(i)%npar
          if (fg_components(i)%gauss_prior(j,2) > 0.d0 .and. fg_components(i)%indregs(j)%independent_pixels) then
             prior = prior + (fg_ind(l)-fg_components(i)%gauss_prior(j,1))**2 / &
                  & fg_components(i)%gauss_prior(j,2)**2
          end if
          l = l+1
       end do
    end do

    fg_init_chisq = chisq + prior
    
    if (.false.) then
       write(*,*) 'amp   = ', real(fg_amp,sp)
       write(*,*) 'ind   = ', real(fg_ind,sp)
       write(*,*) 'chisq = ', real(chisq,sp)
       write(*,*) 'prior = ', real(prior,sp)
       write(*,*) 'total = ', real(fg_init_chisq,sp)
       write(*,*)
       
    end if
    !call mpi_finalize(ierr)
    !stop

    deallocate(fg_amp, fg_ind)

  end function fg_init_chisq
  

  subroutine enforce_pos_amp(chaindir, residuals_in, inv_N_in, fg_amp, fg_param_map_in, doburnin)
    implicit none
    
    character(len=*),                 intent(in),    optional :: chaindir
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: residuals_in
    real(dp), dimension(0:,1:,1:),    intent(inout), optional :: fg_amp
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: inv_N_in
    real(dp), dimension(0:,1:,1:),    intent(in),    optional :: fg_param_map_in
    logical(lgt),                     intent(in),    optional :: doburnin

    integer(i4b) :: i, j, k, l, c, n, fac, mystat, nstep, niter, stat, f, lag, burnin, t, b, nblock, nattempt, nval
    integer(i4b) :: counter
    real(dp)     :: lnL, lnL0, prior, accept, mu0(1,1), sigma0(1,1), xi, corr, chisq, chisq0
    logical(lgt) :: ok, output, firstcall, burnin_
    character(len=2) :: i_text
    character(len=4) :: chain_text
    character(len=256) :: cdir
    real(dp), allocatable, dimension(:)       :: p0, eta, r, sorted, mask2map, W
    real(dp), allocatable, dimension(:,:)     :: M, p_tot, sigma, inv_sigma, map, prop_local
    real(dp), allocatable, dimension(:,:)     :: inv_N_local, sigma_red, mu, mu_red, p, samples
    real(dp), allocatable, dimension(:,:,:)   :: fg_param_map
    real(dp), allocatable, dimension(:,:,:)   :: residuals, my_fg_amp, buffer, fg_amp0
    real(dp), allocatable, dimension(:,:,:)   :: inv_N
    integer(i4b), allocatable, dimension(:)   :: comp, ind
    type(fg_params)                           :: fg_par
    real(dp), allocatable, dimension(:,:,:), save   :: prop
    integer(i4b), allocatable, dimension(:,:), save :: corrlen, buffer_int
    type(task_list)      :: tasks
    integer(i4b), dimension(MPI_STATUS_SIZE)          :: status

    ! Distribute information
    allocate(fg_param_map(0:npix-1, nmaps, num_fg_par))
    allocate(residuals(0:npix-1,nmaps,numband))
    allocate(inv_N(0:npix-1,nmaps,numband))
    allocate(my_fg_amp(0:npix-1,nmaps,num_fg_comp))
    allocate(fg_amp0(0:npix-1,nmaps,num_fg_comp))
    allocate(buffer(0:npix-1,nmaps,num_fg_comp))
    allocate(M(numband,num_fg_comp))

    if (myid_chain == root) then
       burnin_      = doburnin
       residuals    = residuals_in
       inv_N        = inv_N_in
       fg_amp0      = fg_amp
       cdir         = chaindir
       call get_smooth_par_map(fg_param_map_in, fg_param_map)
    end if

    call mpi_bcast(burnin_,      1,                  MPI_LOGICAL,          root, comm_chain, ierr)
    call mpi_bcast(fg_param_map, size(fg_param_map), MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(residuals,    size(residuals),    MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(inv_N,        size(inv_N),        MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(fg_amp0,      size(fg_amp0),      MPI_DOUBLE_PRECISION, root, comm_chain, ierr)
    call mpi_bcast(cdir,         len(cdir),          MPI_CHARACTER,        root, comm_chain, ierr)
    my_fg_amp = -1.d60
    ! write(*,*) "ENFORCING POS AMPLITUDES"
    nval = count(inv_N(:,1,1) /= 0.d0)
    allocate(mask2map(nval))
    j = 1
    do i = 0, npix-1
       if (inv_N(i,1,1) /= 0.d0) then
          mask2map(j) = i
          j           = j+1
       end if
    end do

    if (.not. allocated(corrlen)) then
       allocate(corrlen(0:npix-1,num_fg_comp))
       corrlen = 0

!!$       inquire(file=trim(cdir)//'/corrlen.unf',exist=ok)
!!$       if (ok .and. .not. burnin_) then
!!$          open(58,file=trim(cdir)//'/corrlen.unf',form='unformatted')
!!$          read(58) corrlen
!!$          close(58)
!!$       end if

    end if

    allocate(inv_N_local(numband,numband), r(numband), p(num_fg_comp,1), p0(num_fg_comp), &
         & eta(num_fg_comp), mu(num_fg_comp,1), inv_sigma(num_fg_comp,num_fg_comp), &
         & sigma(num_fg_comp,num_fg_comp), sigma_red(num_fg_comp-1,num_fg_comp-1), &
         & mu_red(num_fg_comp-1,1), ind(num_fg_comp-1))

    nblock = 50
!    call int2string(chain, chain_text)
!    call init_task_list(tasks, trim(cdir) // '/tasks'//chain_text//'.dat', nval/nblock+1, comm_chain)

    !do while(get_next_task(tasks, t))
    do t = 1+myid_chain, nval/nblock+1, numprocs_chain
       !if (mod(t,100) == 0) write(*,*) myid_chain, ' processing ', (t-1)*nblock, ' to ', min(t*nblock-1, npix-1)
       do b = (t-1)*nblock+1, min(t*nblock, nval)
          i = mask2map(b)

          ! Compute mixing matrix for this pixel
          call reorder_fg_params(fg_param_map(i,:,:), fg_par)
          do k = 1, numband
             do j = 1, num_fg_comp
                M(k,j) = get_effective_fg_spectrum(fg_components(j), k, fg_par%comp(j)%p(1,:), pixel=i, pol=1)
             end do
          end do
          call deallocate_fg_params(fg_par)

          ! Compute joint mean and covariance
          inv_N_local = 0.d0
          do j = 1, numband
             inv_N_local(j,j) = inv_N(i,1,j)
          end do
          inv_sigma = matmul(transpose(M), matmul(inv_N_local, M))
          sigma = inv_sigma
          call invert_matrix_with_mask(sigma)
          mu = matmul(sigma, matmul(transpose(M), matmul(inv_N_local, transpose(residuals(i:i,1,:)))))

          ! Measure correlation length
          p(:,1) = fg_amp0(i,1,:)

          chisq0 = 0.d0
          do j = 1, numband
             chisq0 = chisq0 + (residuals(i,1,j)-sum(M(j,:)*p(:,1)))**2 * inv_N(i,1,j)
          end do

          if (trim(operation) == 'optimize') then
             if (corrlen(i,1) == 0) then
                corrlen(i,:) = 1
                do f = 1, num_fg_comp
                   if (trim(fg_components(f)%type) == 'freefree_EM') corrlen(i,f) = -1
                   if (.not. enforce_zero_cl .and. trim(fg_components(f)%type) == 'cmb' &
                        & .and. mask_lowres(i,1) > 0.5d0) corrlen(i,f) = -1
                   if (all(M(:,f) == 0.d0)) corrlen(i,f) = -1
                end do
             end if
          else
             if (corrlen(i,1) == 0) then
                nstep = 200
                do while (.true.)
                   burnin = 0.1*nstep
                   allocate(samples(num_fg_comp,nstep))
                   
                  ! Run test chain
                   do c = 1, nstep
                      do f = 1, num_fg_comp
                         !if (.not. fg_components(f)%enforce_positive_amplitude) cycle
                         if (trim(fg_components(f)%type) == 'freefree_EM') cycle
                         if (.not. enforce_zero_cl .and. trim(fg_components(f)%type) == 'cmb' &
                              & .and. mask_lowres(i,1) > 0.5d0) cycle
                         if (all(M(:,f) == 0.d0)) then
                            p(f,1) = 0.d0
                         else
                            l = 1
                            do k = 1, num_fg_comp
                               if (k /= f) then
                                  ind(l) = k
                                  l      = l+1
                               end if
                            end do
                            sigma_red = sigma(ind,ind)
                            if (num_fg_comp > 0 .and. any(sigma_red /= 0.d0)) then
                               call invert_matrix_with_mask(sigma_red)
                               mu0    = mu(f,1)         + matmul(sigma(f:f,ind), matmul(sigma_red, p(ind,:)-mu(ind,1:1)))
                               sigma0 = sqrt(sigma(f,f) - matmul(sigma(f:f,ind), matmul(sigma_red, sigma(ind,f:f))))
                            else
                               mu0    = mu(f,1)
                               sigma0 = sqrt(sigma(f,f))
                            end if
                            
                            if (fg_components(f)%enforce_positive_amplitude) then
                               if (mu0(1,1) < 0.d0) then
                                  xi = rand_trunc_gauss(handle, mu0(1,1), 0.d0, sigma0(1,1))
                               else
                                  xi = -1d30
                                  do while (xi < 0.d0)
                                     xi = mu0(1,1) + sigma0(1,1) * rand_gauss(handle)
                                  end do
                               end if
                            else
                               xi = mu0(1,1) + sigma0(1,1) * rand_gauss(handle)
                            end if
                            p(f,1) = xi
                         end if
                      end do
                      samples(:,c) = p(:,1)
                      fg_amp0(i,1,:) = p(:,1)
                   end do
                   
                   ! Compute correlation length
                   do f = 1, num_fg_comp
                      if ((.not. enforce_zero_cl .and. trim(fg_components(f)%type) == 'cmb' .and. &
                           & mask_lowres(i,1) > 0.5d0) .or. all(M(:,f) == 0.d0) .or. &
                           & trim(fg_components(f)%type) == 'freefree_EM') then
                         !if (.not. fg_components(f)%enforce_positive_amplitude .or. all(M(:,f) == 0.d0)) then
                         !if (all(M(:,f) == 0.d0)) then
                         corrlen(i,f) = -1
                         cycle
                      end if
                      mu0    = mean(samples(f,burnin+1:nstep))
                      sigma0 = sqrt(variance(samples(f,burnin+1:nstep)))
                      if (sigma0(1,1) == 0.d0) then
                         corrlen(i,f) = -1
                      else
                         do lag = 1, nint(0.2d0*nstep)
                            corr   = sum((samples(f,burnin+1:nstep-lag)-mu0(1,1)) * &
                                 & (samples(f,burnin+1+lag:nstep)-mu0(1,1))) / (nstep-burnin-lag) / sigma0(1,1)**2
                            if (corr < 0.2d0) exit
                         end do
                         corrlen(i,f) = lag
                      end if
                   end do
                   
                   deallocate(samples)
                   if (all(corrlen(i,:) < 0.2d0*nstep) .or. nstep > 100000) then
                      exit
                   else
                      nstep = nstep*10
                      if (nstep > 10000) write(*,*) i, myid_chain, ' increasing nstep to ', nstep
                   end if
                end do
                if (mod(i,1000) == 0) write(*,fmt='(2i8,a,5i8)') i, myid_chain, ', corrlen = ', corrlen(i,:)
             
             end if
          end if

          ! Set up sampling order
          n = 0
          do k = 1, num_fg_comp
             if (corrlen(i,k) > 0) n = n + corrlen(i,k)
          end do
          allocate(comp(n), sorted(n))
          j = 1
          do k = 1, num_fg_comp
             if (corrlen(i,k) > 0) then
                comp(j:j+corrlen(i,k)-1) = k
                j                        = j + corrlen(i,k)
             end if
          end do
          
          ! Randomize sampling order
          do k = 1, n
             sorted(k) = rand_uni(handle)
          end do
          call QuickSort(comp, sorted)
          deallocate(sorted)

          ! Run a Gibbs chain over components
          p(:,1) = fg_amp0(i,1,:)
          nstep = 10
          do c = 1, nstep
             do f = 1, n
                j = comp(f)
                ! Compute mean and standard deviation
                l = 1
                do k = 1, num_fg_comp
                   if (k /= j) then
                      ind(l) = k
                      l      = l+1
                   end if
                end do
                sigma_red = sigma(ind,ind)
                if (num_fg_comp > 0 .and. any(sigma_red /= 0.d0)) then
                   call invert_matrix_with_mask(sigma_red)
                   mu0    = mu(j,1)         + matmul(sigma(j:j,ind), matmul(sigma_red, p(ind,:)-mu(ind,1:1)))
                   sigma0 = sqrt(sigma(j,j) - matmul(sigma(j:j,ind), matmul(sigma_red, sigma(ind,j:j))))
                else
                   mu0    = mu(j,1)
                   sigma0 = sqrt(sigma(j,j))
                end if

!!$                if (mu0(1,1) > 1.d27) then
!!$                   if (myid_chain == root) then
!!$                      write(*,*) 'p = ', p(ind,1)
!!$                      do l = 1, size(ind)
!!$                         write(*,*) real(sigma_red(l,:),sp)
!!$                      end do
!!$                      allocate(W(size(ind)))
!!$                      call get_eigenvalues(sigma_red, W)
!!$                      write(*,*) 'W = ', real(W,sp)
!!$                   end if
!!$                   call mpi_finalize(ierr)
!!$                   stop
!!$                end if

                if (trim(operation) == 'optimize') then
                   if (fg_components(j)%enforce_positive_amplitude .and. mu0(1,1) < 0.d0) then
                      xi = 0.d0
                   else
                      xi = mu0(1,1)
                   end if
                else
                   if (fg_components(j)%enforce_positive_amplitude) then
                      if (mu0(1,1) < 0.d0) then
                         xi = rand_trunc_gauss(handle, mu0(1,1), 0.d0, sigma0(1,1))
                      else
                         xi = -1d30
                         nattempt = 0
                         do while (xi < 0.d0)
                            xi = mu0(1,1) + sigma0(1,1) * rand_gauss(handle)
                            nattempt = nattempt + 1
                            if (mod(nattempt,100) == 0) write(*,*) 'loop', real(mu0(1,1),sp), &
                                 & real(sigma0(1,1),sp), real(xi,sp)
                         end do
                      end if
                   else
                      xi = mu0(1,1) + sigma0(1,1) * rand_gauss(handle)
                   end if
                end if
                p(j,1) = xi
             end do
          end do
          if (myid_chain == root) then
             ! write(*,*) "Enforcing positive amplitude"
          endif
          my_fg_amp(i,1,:) = p(:,1)

          chisq = 0.d0
          do j = 1, numband
             chisq = chisq + (residuals(i,1,j)-sum(M(j,:)*p(:,1)))**2 * inv_N(i,1,j)
          end do

!          if (myid_chain == root) write(*,*) i, real(chisq0,sp), real(chisq,sp), ' AA'
!!$          if (chisq-chisq0 > 0.d0 .and. myid_chain == root) then
!!$             write(*,*) 'AA', i, real(chisq0,sp), real(chisq,sp), real(chisq-chisq0,sp)
!!$             write(*,*) 'AA', i, p(:,1)
!!$             write(*,*) 'AA', i, mu
!!$             write(*,*) 'AA', i, sigma
!!$          end if

          deallocate(comp)
       end do

    end do
    !call free_task_list(tasks)
    
    if (any(corrlen == 0)) then
       inquire(file=trim(cdir)//'/corrlen.unf',exist=ok)
       allocate(buffer_int(0:npix-1,num_fg_comp))
       where (corrlen == -1)
          corrlen = 10000000
       end where
       call mpi_allreduce(corrlen, buffer_int, size(buffer_int), MPI_INTEGER, MPI_MAX, comm_chain, ierr)
       corrlen = buffer_int
       deallocate(buffer_int)
       if (myid_chain == root .and. all(corrlen /= 0) .and. .not. ok) then
          where (corrlen == 10000000)
             corrlen = -1
          end where
          open(58,file=trim(cdir)//'/corrlen.unf',form='unformatted')
          write(58) corrlen
          close(58)
       else
          where (corrlen == 10000000)
             corrlen = -1
          end where
       end if
    end if

    ! Do the reduce operation manually, because the task module doesn't seem to work perfectly on abel
    if (myid_chain == root) then
       fg_amp = fg_amp0
       where(my_fg_amp /= -1.d60) 
          fg_amp = my_fg_amp
       end where
       do i = 1, numprocs_chain-1
          call mpi_recv(my_fg_amp, size(my_fg_amp), MPI_DOUBLE_PRECISION, i, 99, comm_chain, status, ierr)
          where (my_fg_amp /= -1.d60)
             fg_amp = my_fg_amp
          end where
       end do
    else
        call mpi_send(my_fg_amp, size(my_fg_amp), MPI_DOUBLE_PRECISION, root, 99, comm_chain, ierr)
    end if

!    call mpi_reduce(my_fg_amp, buffer, size(buffer), MPI_DOUBLE_PRECISION, MPI_SUM, root, comm_chain, ierr)
!    if (myid_chain == root) fg_amp = buffer
    deallocate(buffer)

    deallocate(inv_N_local, r, p, p0, eta, M)
    deallocate(fg_param_map, residuals, inv_N, my_fg_amp, fg_amp0, mu, sigma)
    deallocate(inv_sigma, sigma_red, mu_red, ind, mask2map)

  end subroutine enforce_pos_amp


  function rand_trunc_gauss(rng_handle, mu, mu_, sigma)
    implicit none

    real(dp),         intent(in)    :: mu, mu_, sigma
    type(planck_rng), intent(inout) :: rng_handle
    real(dp)                        :: rand_trunc_gauss

    integer(i4b) :: n
    real(dp) :: eta, alpha, z, rho, u, mu0
    logical(lgt) :: ok

    mu0   = (mu_ - mu)/sigma
    alpha = 0.5d0 * (mu0 + sqrt(mu0**2 + 4.d0))
    do while (.true.)
       z   = -log(rand_uni(rng_handle)) / alpha + mu0
       rho = exp(-0.5d0 * (z-alpha)**2)
       if (rand_uni(rng_handle) < rho) then
          rand_trunc_gauss = sigma*z + mu
          exit
       end if
    end do

  end function rand_trunc_gauss

end module comm_fg_mod
