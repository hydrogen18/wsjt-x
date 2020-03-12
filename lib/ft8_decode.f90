module ft8_decode

  parameter (MAXFOX=1000)
  character*12 c2fox(MAXFOX)
  character*4  g2fox(MAXFOX)
  integer nsnrfox(MAXFOX)
  integer nfreqfox(MAXFOX)
  integer n30fox(MAXFOX)
  integer n30z
  integer nfox
  
  type :: ft8_decoder
     procedure(ft8_decode_callback), pointer :: callback
   contains
     procedure :: decode
  end type ft8_decoder

  abstract interface
     subroutine ft8_decode_callback (this,sync,snr,dt,freq,decoded,nap,qual)
       import ft8_decoder
       implicit none
       class(ft8_decoder), intent(inout) :: this
       real, intent(in) :: sync
       integer, intent(in) :: snr
       real, intent(in) :: dt
       real, intent(in) :: freq
       character(len=37), intent(in) :: decoded
       integer, intent(in) :: nap 
       real, intent(in) :: qual 
     end subroutine ft8_decode_callback
  end interface

contains

  subroutine decode(this,callback,iwave,nQSOProgress,nfqso,nftx,newdat,  &
       nutc,nfa,nfb,nzhsym,ndepth,ncontest,nagain,lft8apon,lapcqonly,    &
       napwid,mycall12,hiscall12,hisgrid6,ss0,ldiskdat)
    use timer_module, only: timer
    include 'ft8/ft8_params.f90'

    class(ft8_decoder), intent(inout) :: this
    procedure(ft8_decode_callback) :: callback
    parameter (MAXCAND=300,MAX_EARLY=100)
    real s(NH1,NHSYM)
    real sbase(NH1)
    real candidate(3,MAXCAND)
    real dd(15*12000),dd1(15*12000)
    logical, intent(in) :: lft8apon,lapcqonly,nagain
    logical newdat,lsubtract,ldupe,lrefinedt
    logical*1 ldiskdat
    logical lsubtracted(MAX_EARLY)
    character*12 mycall12,hiscall12
    character*6 hisgrid6
    integer*2 iwave(15*12000)
    integer apsym2(58),aph10(10)
    character datetime*13,msg37*37
    character*37 allmessages(100)
    integer allsnrs(100)
    integer itone(NN)
    integer itone_save(NN,MAX_EARLY)
    integer itime(8)
    real f1_save(MAX_EARLY)
    real xdt_save(MAX_EARLY)

    save s,dd,dd1,ndec_early,itone_save,f1_save,xdt_save,lsubtracted
    volatile ss0

    this%callback => callback
    write(datetime,1001) nutc        !### TEMPORARY ###
1001 format("000000_",i6.6)

    call ft8apset(mycall12,hiscall12,ncontest,apsym2,aph10)
    if(nzhsym.le.47) dd=iwave
    if(nzhsym.eq.41) then
       ndecodes=0
       allmessages='                                     '
       allsnrs=0
    else
       ndecodes=ndec_early
    endif
    if(nzhsym.eq.47 .and. ndec_early.ge.1) then
       lsubtracted=.false.
       lrefinedt=.true.
       if(ndepth.le.2) lrefinedt=.false.
       call timer('sub_ft8b',0)
       do i=1,ndec_early
          if(xdt_save(i)-0.5.lt.0.396) then
             call subtractft8(dd,itone_save(1,i),f1_save(i),xdt_save(i),  &
                  lrefinedt)
             lsubtracted(i)=.true.
          endif
          if(.not.ldiskdat .and. nint(ss0).ge.49) then !Bail out before done
             call timer('sub_ft8b',1)
             dd1=dd
             go to 700
          endif
       enddo
       call timer('sub_ft8b',1)
       dd1=dd
       go to 900
    endif
    if(nzhsym.eq.50 .and. ndec_early.ge.1) then
       n=47*3456
       dd(1:n)=dd1(1:n)
       dd(n+1:)=iwave(n+1:)
       call timer('sub_ft8c',0)
       do i=1,ndec_early
          if(lsubtracted(i)) cycle
          call subtractft8(dd,itone_save(1,i),f1_save(i),xdt_save(i),.true.)
       enddo
       call timer('sub_ft8c',1)
    endif
    ifa=nfa
    ifb=nfb
    if(nagain) then
       ifa=nfqso-10
       ifb=nfqso+10
    endif

! For now:
! ndepth=1: no subtraction, 1 pass, belief propagation only
! ndepth=2: subtraction, 3 passes, bp+osd (no subtract refinement) 
! ndepth=3: subtraction, 3 passes, bp+osd
    if(ndepth.eq.1) npass=1
    if(ndepth.ge.2) npass=3
    do ipass=1,npass
      newdat=.true.
      syncmin=1.3
      if(ipass.eq.1) then
        lsubtract=.true.
        if(ndepth.eq.1) lsubtract=.false.
      elseif(ipass.eq.2) then
        n2=ndecodes
        if(ndecodes.eq.0) cycle
        lsubtract=.true.
      elseif(ipass.eq.3) then
        if((ndecodes-n2).eq.0) cycle
        lsubtract=.true. 
      endif 
      call timer('sync8   ',0)
      maxc=MAXCAND
      call sync8(dd,ifa,ifb,syncmin,nfqso,maxc,s,candidate,   &
           ncand,sbase)
      call timer('sync8   ',1)
      do icand=1,ncand
        sync=candidate(3,icand)
        f1=candidate(1,icand)
        xdt=candidate(2,icand)
        xbase=10.0**(0.1*(sbase(nint(f1/3.125))-40.0))
        call timer('ft8b    ',0)
        call ft8b(dd,newdat,nQSOProgress,nfqso,nftx,ndepth,nzhsym,lft8apon, &
             lapcqonly,napwid,lsubtract,nagain,ncontest,iaptype,mycall12,   &
             hiscall12,sync,f1,xdt,xbase,apsym2,aph10,nharderrors,dmin,     &
             nbadcrc,iappass,iera,msg37,xsnr,itone)
        call timer('ft8b    ',1)
        nsnr=nint(xsnr) 
        xdt=xdt-0.5
        hd=nharderrors+dmin
        if(nbadcrc.eq.0) then
           ldupe=.false.
           do id=1,ndecodes
!              if(msg37.eq.allmessages(id).and.nsnr.le.allsnrs(id)) ldupe=.true.
              if(msg37.eq.allmessages(id)) ldupe=.true.
           enddo
           if(.not.ldupe) then
              ndecodes=ndecodes+1
              allmessages(ndecodes)=msg37
              allsnrs(ndecodes)=nsnr
              f1_save(ndecodes)=f1
              xdt_save(ndecodes)=xdt+0.5
              itone_save(1:NN,ndecodes)=itone
           endif
           if(.not.ldupe .and. associated(this%callback)) then
              qual=1.0-(nharderrors+dmin)/60.0 ! scale qual to [0.0,1.0]
              call this%callback(sync,nsnr,xdt,f1,msg37,iaptype,qual)
           endif
        endif
        if(.not.ldiskdat .and. nzhsym.eq.41 .and.                        &
             nint(ss0).ge.46) go to 700                 !Bail out before done
      enddo
   enddo
   go to 800
   
700 call date_and_time(values=itime)
   tsec=mod(itime(7)+0.001*itime(8),15.0)
   if(tsec.lt.9.0) tsec=tsec+15.0
   write(71,3001) 'BB Bail ',nzhsym,nint(ss0),nutc,tsec,ndecodes
3001 format(a8,2i6,i8,f8.3,i6)
   flush(71)
   
800 ndec_early=0
   if(nzhsym.lt.50) ndec_early=ndecodes
   
900 return
end subroutine decode

end module ft8_decode
