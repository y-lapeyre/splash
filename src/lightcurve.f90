!-----------------------------------------------------------------
!
!  This file is (or was) part of SPLASH, a visualisation tool
!  for Smoothed Particle Hydrodynamics written by Daniel Price:
!
!  http://users.monash.edu.au/~dprice/splash
!
!  SPLASH comes with ABSOLUTELY NO WARRANTY.
!  This is free software; and you are welcome to redistribute
!  it under the terms of the GNU General Public License
!  (see LICENSE file for details) and the provision that
!  this notice remains intact. If you modify this file, please
!  note section 2a) of the GPLv2 states that:
!
!  a) You must cause the modified files to carry prominent notices
!     stating that you changed the files and the date of any change.
!
!  Copyright (C) 2021- Daniel Price. All rights reserved.
!  Contact: daniel.price@monash.edu
!
!-----------------------------------------------------------------
module lightcurve
 use params, only:int1,doub_prec
 implicit none

 public :: get_lightcurve
 public :: get_temp_from_u,ionisation_fraction

 private

contains

!---------------------------------------------------------
! routine to to compute luminosity, effective temperature
! effective blackbody radius, Reff, vs time from
! SPH particle data
!
! We solve the equation of radiative transfer along a
! ray for each pixel in the image, performing the ray
! trace through particles assuming grey blackbody
! emission (i.e. each particle emits sigma*T^4)
!
! We then compute the emitting area (area of optically
! thick material) and the effective temperature, putting
! these together to give a total luminosity
!
! Used to generate synthetic lightcurves
!---------------------------------------------------------
subroutine get_lightcurve(ncolumns,dat,npartoftype,masstype,itype,ndim,ntypes,&
                          lum,rphoto,temp,lum_bb,r_bb,Tc,specfile)
 use labels,                only:ix,ih,irho,ipmass,itemp,ikappa
 use limits,                only:lim,get_particle_subset
 use interpolate3D_opacity, only:interp3D_proj_opacity
 use particle_data,         only:icolourme
 use interpolation,         only:get_n_interp,set_interpolation_weights
 use settings_data,         only:iRescale,iverbose,required,UseTypeInRenderings
 use settings_part,         only:iplotpartoftype
 use settings_render,       only:npix,inormalise=>inormalise_interpolations,&
                                 idensityweightedinterpolation,exact_rendering
 use settings_units,        only:units,unit_interp
 use physcon,               only:steboltz,pi,au,rsun=>solarrcgs,Lsun,c,cm_to_nm
 use write_pixmap,          only:write_pixmap_ascii
 use filenames,             only:tagline
 use blackbody,             only:B_nu,logspace,Wien_nu_from_T,nu_to_lam,&
                                 integrate_log,get_colour_temperature
 use settings_xsecrot,      only:anglex,angley,anglez
 use rotation,              only:rotate3D
 integer, intent(in)  :: ncolumns,ntypes,ndim
 integer, intent(in)  :: npartoftype(:)
 integer(kind=int1), intent(in) :: itype(:)
 real,    intent(in)  :: masstype(:)
 real,    intent(in)  :: dat(:,:)
 real,    intent(out) :: lum,rphoto,temp,lum_bb,r_bb,Tc
 character(len=*), intent(in) :: specfile
 integer :: n,isinktype,npixx,npixy,ierr,j,i,nfreq
 integer, parameter :: iu1 = 45
 real, dimension(3) :: xmin,xmax
 real, dimension(:),   allocatable :: weight,x,y,z,flux,opacity
 real, dimension(:),   allocatable :: freq,spectrum,bb_spectrum
 real, dimension(:,:), allocatable :: img,taupix,flux_nu
 real, dimension(:,:,:), allocatable :: img_nu
 real :: zobs,dzobs,dx,dy,area,freqmin,freqmax,lam_max,freq_max,bb_scale
 real :: ax,ay,az,xi(3)

 lum = 0.
 rphoto = 0.
 temp = 0.
 if (ndim /= 3) then
    print "(a)",' ERROR: lightcurve only works with 3 dimensional data'
    return
 endif
 if (.not. (ih > 0 .and. ipmass > 0 .and. irho > 0 .and. itemp > 0)) then
    print "(a)",' ERROR: could not locate h,mass,rho or temperature in data'
    return
 endif
 xmin(1:ndim) = lim(ix(1:ndim),1)
 xmax(1:ndim) = lim(ix(1:ndim),2)
 !
 !--set number of particles to use in the interpolation routines
 !  and allocate memory for weights
 !
 n = get_n_interp(ntypes,npartoftype,UseTypeInRenderings,iplotpartoftype,size(itype),.false.)
 allocate(weight(n),x(n),y(n),z(n),flux(n),opacity(n),stat=ierr)
 if (ierr /= 0) then
    print*,' ERROR allocating memory for interpolation weights, aborting...'
    return
 endif
 x(1:n) = dat(1:n,ix(1))
 y(1:n) = dat(1:n,ix(2))
 z(1:n) = dat(1:n,ix(3))
 if (abs(anglez)>0. .or. abs(angley)>0. .or. abs(anglex)>0.) then
    print*, 'Rotating particles around (z,y,x) by',anglez,angley,anglex
    ax = anglex*pi/180.0 ! convert degrees to radians to pass into rotate
    ay = angley*pi/180.0
    az = anglez*pi/180.0
    do i=1,n
       xi = (/x(i),y(i),z(i)/)
       call rotate3D(xi,ax,ay,az,0.,0.)
       x(i) = xi(1)
       y(i) = xi(2)
       z(i) = xi(3)
    enddo
 endif

 !
 !--set number of pixels and pixel scale in each direction
 !
 !do j=6,12
 npixx = npix !2**j
 if (npixx < 8) npixx = 1024
 dx = (xmax(1)-xmin(1))/npixx
 npixy = int((xmax(2)-xmin(2) - 0.5*dx)/dx) + 1
 dy = (xmax(2)-xmin(2))/npixy
 print "(a,i0,a,i0,a)",' Using ',npixx,' x ',npixy,' pixels'
 print "(2(1x,a,es10.3,'->',es10.3,a,/))",'x = [',xmin(1),xmax(1),']','y = [',xmin(2),xmax(2),']'
 !
 !--allocate memory for image
 !
 if (allocated(img) .or. allocated(taupix)) deallocate(img,taupix)
 allocate(img(npixx,npixy),taupix(npixx,npixy))
 !
 !--set interpolation weights (w = m/(rho*h^ndim)
 !
 isinktype = 0 !get_sink_type(ntypes)
 call set_interpolation_weights(weight,dat,itype,(iplotpartoftype .and. UseTypeInRenderings),&
      n,npartoftype,masstype,ntypes,ncolumns,irho,ipmass,ih,ndim,iRescale,&
      idensityweightedinterpolation,inormalise,units,unit_interp,required,.false.,isinktype)
 !
 !--set default mask and apply range restrictions to data
 !
 icolourme(:) = 1
 call get_particle_subset(icolourme,dat,ncolumns)

 !
 ! specify opacity
 !
 if (ikappa > 0) then
    opacity = dat(1:n,ikappa)
 else
    print*,' WARNING: using fixed opacity kappa = 0.3 cm^2/g for lightcurve'
    opacity = 0.3
 endif
 !
 ! specify source function for each particle
 !
 flux = steboltz*dat(1:n,itemp)**4 ! grey version

 ! frequency-dependent version
 nfreq = 128
 freqmin = 1e8
 freqmax = 1e22
 freq = logspace(nfreq,freqmin,freqmax)  ! frequency grid in Hz
 allocate(flux_nu(nfreq,n))
 do i=1,n
    flux_nu(:,i) = B_nu(dat(i,itemp),freq)
 enddo
 if (allocated(img_nu)) deallocate(img_nu)
 allocate(img_nu(nfreq,npixx,npixy))
 !
 ! raytrace SPH data to 2D image to get flux
 !
 zobs = huge(zobs)  ! no 3D perspective
 dzobs = 0.
 call interp3D_proj_opacity(x,y,z,&
      dat(1:n,ipmass),n,dat(1:n,ih),weight, &
      flux,z,icolourme(1:n), &
      n,xmin(1),xmin(2),img,taupix,npixx,npixy,&
      dx,dy,zobs,dzobs,opacity,huge(zobs),iverbose,.false.,datv=flux_nu,datvpix=img_nu)

 lum = 4.*sum(img)*dx*dy
 print*,'grey luminosity = ',lum,' erg/s'

 ! integrate flux over all frequencies to give Flux = \int F_\nu d\nu = pi \int B_nu dnu
 do j=1,npixy
    do i=1,npixx
       img(i,j) = pi*integrate_log(img_nu(1:nfreq,i,j),freq,freqmin,freqmax)
    enddo
 enddo

 lum = 4.*sum(img)*dx*dy

 ! luminosity is integrated flux
 print "(/,a,2(es10.3,a))",' L_bol = ',lum,' erg/s = ',lum/Lsun,' L_sun'

 area = count(taupix >= 1.)*dx*dy
 print "(a,1pg10.3,a)",' emitting area = ',area/au**2,' au^2'
 print "(/,a,1pg10.3,a)",' Tmax  = ',(maxval(img)/steboltz)**0.25,' K'

 ! effective temperature: total flux equals that of a blackbody at T=Teff
 temp = (lum/area/(4.*steboltz))**0.25
 freq_max = Wien_nu_from_T(temp)
 lam_max = c/freq_max*cm_to_nm
 print "(a,3(1pg10.3,a))",' Teff  = ',temp,' K: Blackbody peak at ',freq_max,' Hz / ',lam_max,' nm'

 ! get integrated spectrum from integrating over all pixels in the image
 allocate(spectrum(nfreq),bb_spectrum(nfreq))
 do i=1,nfreq
    spectrum(i) = sum(img_nu(i,1:npixx,1:npixy))*dx*dy
 enddo

 ! get colour temperature by fitting the blackbody peak
 call get_colour_temperature(spectrum,freq,Tc,freq_max,bb_scale)
 print "(a,3(1pg10.3,a))",' Tc    = ',Tc,' K: Blackbody peak at ',freq_max,' Hz / ',nu_to_lam(freq_max),' nm'

 ! effective photospheric radius, using Teff
 rphoto = sqrt(lum/(4.*pi*steboltz*temp**4))
 print "(a,2(es10.3,a))",' R_eff = ',rphoto/au,' au = ',rphoto/rsun,' rsun'

 ! L_bb and effective photospheric radius, using blackbody at T=Tc
 bb_spectrum = B_nu(Tc,freq(:))*bb_scale
 lum_bb = 4.*pi*integrate_log(bb_spectrum(1:nfreq),freq,freqmin,freqmax)
 print "(a,2(es10.3,a))",' L_bb  = ',lum_bb
 r_bb = sqrt(lum_bb/(4.*pi*steboltz*Tc**4))
 print "(a,2(es10.3,a))",' R_bb  = ',r_bb/au,' au = ',r_bb/rsun,' rsun'

 print "(a)",' WRITING '//trim(specfile)//'.spec'
 open(unit=iu1,file=trim(specfile)//'.spec',status='replace',iostat=ierr)
 write(iu1,"(a)") '# model spectrum, computed with '//trim(tagline)
 write(iu1,"(a)") '# wavelength [nm], F_\lambda'
 do i=1,nfreq
    write(iu1,*) nu_to_lam(freq(i)),spectrum(i)
 enddo
 close(iu1)

end subroutine get_lightcurve

!---------------------------------------------------------
! routine to to compute temperature from
! internal energy assuming a mix of gas and radiation
! pressure, where Trad = Tgas. That is, we solve the
! quartic equation
!
!  a*T^4 + 3/2*rho*kb*T/mu = rho*u
!
! to determine the temperature from the supplied density
! and internal energy (rho, u).
! INPUT:
!    rho - density [g/cm^3]
!    u - internal energy [erg/g]
! OUTPUT:
!    temp - temperature [K]
!---------------------------------------------------------
real elemental function get_temp_from_u(rho,u) result(temp)
 use physcon, only:kb_on_mh,radconst
 real(doub_prec), intent(in) :: rho,u
 real(doub_prec) :: ft,dft,dt
 real(doub_prec), parameter :: tol = 1.e-8
 real(doub_prec), parameter :: mu = 0.6
 integer :: its

 ! Take minimum of gas and radiation temperatures as initial guess
 temp = min(u*mu/(1.5*kb_on_mh),(u*rho/radconst)**0.25)

 dt = huge(0.)
 its = 0
 do while (abs(dt) > tol*temp .and. its < 500)
    its = its + 1
    ft = u*rho - 1.5*kb_on_mh*temp*rho/mu - radconst*temp**4
    dft = - 1.5*kb_on_mh*rho/mu - 4.*radconst*temp**3
    dt = ft/dft ! Newton-Raphson
    if (temp - dt > 1.2*temp) then
       temp = 1.2*temp
    elseif (temp - dt < 0.8*temp) then
       temp = 0.8*temp
    else
       temp = temp - dt
    endif
 enddo

end function get_temp_from_u

!----------------------------------------------------------------
!+
!  Solves three Saha equations simultaneously to return ion
!  fractions of hydrogen and helium. Assumes inputs in cgs units
!+
!----------------------------------------------------------------
subroutine ionisation_fraction(dens,temp,X,Y,xh0,xh1,xhe0,xhe1,xhe2)
 real, intent(in) :: dens,temp,X,Y
 real, intent(out):: xh0,xh1,xhe0,xhe1,xhe2
 real             :: n,nh,nhe,A,B,C,const,xh1g,xhe1g,xhe2g,f,g,h
 real, parameter  :: chih0=13.6,chihe0=24.6,chihe1=54.4
 real, dimension(3,3) :: M, M_inv
 real, dimension(3) :: dx
 integer          :: i
 real, parameter :: twopi=6.2831853072d0,kboltz=1.38066d-16,eV=1.60219d-12,&
                    planckh=6.6260755d-27,mass_electron_cgs=9.10938291d-28,mass_proton_cgs=1.67262158d-24

 nh = X * dens / mass_proton_cgs
 nhe = Y * dens / (4. * mass_proton_cgs)
 n = nh + nhe

 const = (sqrt(twopi * mass_electron_cgs * kboltz) / planckh)**3 / n

 A = 1. * const * temp**(1.5) * exp(-chih0 * eV / (kboltz * temp))
 B = 4. * const * temp**(1.5) * exp(-chihe0 * eV / (kboltz * temp))
 C = 1. * const * temp**(1.5) * exp(-chihe1 * eV / (kboltz * temp))

 xh1g = 0.4
 xhe1g = 0.3
 xhe2g = 0.2

 do i=1,50
    f = xh1g * (xh1g + xhe1g + 2*xhe2g) - A * ((nh/n) - xh1g)
    g = xhe1g * (xh1g + xhe1g + 2*xhe2g) - B * ((nhe/n) - xhe1g - xhe2g)
    h = xhe2g * (xh1g + xhe1g + 2*xhe2g) - C * xhe1g

    M(1,:) = (/ 2*xh1g + xhe1g + 2*xhe2g + A, xh1g, 2*xh1g /)
    M(2,:) = (/ xhe1g, xh1g + 2*xhe1g + 2*xhe2g + B, 2*xhe1g + B /)
    M(3,:) = (/ xhe2g, xhe2g - C, xh1g + xhe1g + 4*xhe2g /)

    call minv(M, M_inv)

    dx = matmul(M_inv, (/ -f, -g, -h/))

    xh1g = xh1g + dx(1)
    xhe1g = xhe1g + dx(2)
    xhe2g = xhe2g + dx(3)
 enddo

 xh1 = xh1g * n / nh
 xhe1 = xhe1g * n / nhe
 xhe2 = xhe2g * n / nhe
 xh0 = ((nh/n) - xh1g) * n / nh
 xhe0 = ((nhe/n) - xhe1g - xhe2g) * n / nhe
end subroutine ionisation_fraction



subroutine minv (M, M_inv)

 implicit none

 real, dimension(3,3), intent(in)  :: M
 real, dimension(3,3), intent(out) :: M_inv

 real :: det
 real, dimension(3,3) :: cofactor


 det =   M(1,1)*M(2,2)*M(3,3)  &
       - M(1,1)*M(2,3)*M(3,2)  &
       - M(1,2)*M(2,1)*M(3,3)  &
       + M(1,2)*M(2,3)*M(3,1)  &
       + M(1,3)*M(2,1)*M(3,2)  &
       - M(1,3)*M(2,2)*M(3,1)

 cofactor(1,1) = +(M(2,2)*M(3,3)-M(2,3)*M(3,2))
 cofactor(1,2) = -(M(2,1)*M(3,3)-M(2,3)*M(3,1))
 cofactor(1,3) = +(M(2,1)*M(3,2)-M(2,2)*M(3,1))
 cofactor(2,1) = -(M(1,2)*M(3,3)-M(1,3)*M(3,2))
 cofactor(2,2) = +(M(1,1)*M(3,3)-M(1,3)*M(3,1))
 cofactor(2,3) = -(M(1,1)*M(3,2)-M(1,2)*M(3,1))
 cofactor(3,1) = +(M(1,2)*M(2,3)-M(1,3)*M(2,2))
 cofactor(3,2) = -(M(1,1)*M(2,3)-M(1,3)*M(2,1))
 cofactor(3,3) = +(M(1,1)*M(2,2)-M(1,2)*M(2,1))

 M_inv = transpose(cofactor) / det

 return

end subroutine minv

end module lightcurve
