program ldpcsim

use, intrinsic :: iso_c_binding
use hashing
use packjt

! To change to a new code, edit the following line and the filenames
! that contain the parity check and generator matrices.
! parameter (N=128, K=80) ! M and N are global variables on the C side.

character*22 msg,msgsent
integer*4 i4Msg6BitWords(12)
integer*1, target:: i1Msg8BitBytes(10) ! 72 bit msg + 8 bit hash
integer*1, target:: i1Dec8BitBytes(10) ! 72 bit msg + 8 bit hash
integer*1 i1hashdec
character*80 prefix
character*85 pchk_file,gen_file
character*8 arg
integer*1, allocatable ::  codeword(:), decoded(:), message(:)
real*8, allocatable ::  lratio(:), rxdata(:)
integer*1 i1hash(4),i1
equivalence (ihash,i1hash)

nargs=iargc()
if(nargs.ne.7) then
   print*,'Usage: ldpcsim pchk/gen file prefix  N  K  niter ndither #trials  s '
   print*,'eg:    ldpcsim  "128-80-peg-reg3"   128 80  10     1     1000    0.75'
   return
endif
call getarg(1,prefix)
call getarg(2,arg)
read(arg,*) N 
call getarg(3,arg)
read(arg,*) K 
call getarg(4,arg)
read(arg,*) max_iterations 
call getarg(5,arg)
read(arg,*) max_dither 
call getarg(6,arg)
read(arg,*) ntrials 
call getarg(7,arg)
read(arg,*) s

pchk_file=trim(prefix)//".pchk"
gen_file=trim(prefix)//".gen"

!rate=real(K)/real(N)
! don't count hash bits as data bits
rate=72.0/real(N)

write(*,*) "pchk file: ",pchk_file
write(*,*) "niter= ",max_iterations," ndither= ",max_dither," s= ",s

allocate ( codeword(N), decoded(K), message(K) )
allocate ( lratio(N), rxdata(N) )
call init_ldpc(trim(pchk_file)//char(0),trim(gen_file)//char(0))

msg="K1JT K9AN EN50"
call fmtmsg(msg,iz)
call packmsg(msg,i4Msg6BitWords,itype)
call unpackmsg(i4Msg6BitWords,msgsent)
write(*,*) "Message: ",msgsent

! Convert from 12 6-bit words to 10 8-bit words
i4=0
ik=0
im=0
do i=1,12
  nn=i4Msg6BitWords(i)
  do j=1, 6
    ik=ik+1
    i4=i4+i4+iand(1,ishft(nn,j-6))
    i4=iand(i4,255)
    if(ik.eq.8) then
      im=im+1
!      if(i4.gt.127) i4=i4-256
      i1Msg8BitBytes(im)=i4
      ik=0
    endif
  enddo
enddo
ihash=nhash(c_loc(i1Msg8BitBytes),int(9,c_size_t),146)
ihash=2*iand(ihash,255)
i1Msg8BitBytes(10)=i1hash(1)

mbit=0
do i=1, 10
  i1=i1Msg8BitBytes(i)
  do ibit=1,8
    mbit=mbit+1
    message(mbit)=iand(1,ishft(i1,ibit-8))
  enddo
enddo 

call ldpc_encode(message,codeword)

write(*,*) "Eb/N0   ngood  nundetected nbadhash"
do idb = 0, 11
  db=idb/2.0-0.5
  sigma=1/sqrt( 2*rate*(10**(db/10.0)) )

  ngood=0
  nue=0
  nbadhash=0

  do itrial=1, ntrials

! create a realization of a noisy received word
    do i=1,N
      rxdata(i) = 2.0*(codeword(i)-0.5) + sigma*gran()
    enddo

! correct signal normalization is important for this decoder.
    rxav=sum(rxdata)/N
    rx2av=sum(rxdata*rxdata)/N
    rxsig=sqrt(rx2av-rxav*rxav)
    rxdata=rxdata/rxsig

! To match the metric to the channel, s should be set to the noise standard deviation. 
! For now we just set s to the value that optimizes decode probability near threshold. 
! The s parameter can be tuned to trade a few tenth's dB of threshold for an order of
! magnitude in UER 
    do i=1,N
      if( s .le. 0 ) then
        ss=sigma
      else 
        ss=s
      endif
      lratio(i)=exp(2.0*rxdata(i)/(ss*ss))
    enddo

! call interface to Radford Neal implementation of binary belief propagation.
! max_iterations is max number of belief propagation iterations
! max_dither is the number of tries - try number 2 and beyond start with dithered likelihood ratios.
    call ldpc_decode(lratio, decoded, max_iterations, niterations, max_dither, ndither)

! if the decoder finds a valid codeword, niterations will be .ge. 0
    if( niterations .ge. 0 ) then
      nueflag=0
      nhashflag=0
! the decoder produced a codeword --- compare hash part of message (byte 10) with computed hash 
! first collapse 80 decoded bits to 10 bytes
! the first 9 bytes are the message, 10'th byte is the hash.
      do ibyte=1,10
        itmp=0
        do ibit=1,8
          itmp=ishft(itmp,1)+iand(1,decoded((ibyte-1)*8+ibit)) 
        enddo
        i1Dec8BitBytes(ibyte)=itmp
      enddo
! calculate the hash using the first 9 bytes
      ihashdec=nhash(c_loc(i1Dec8BitBytes),int(9,c_size_t),146)
      ihashdec=2*iand(ihashdec,255)
! compare calculated hash with received byte 10 - if they agree, keep the message
      i1hashdec=ihashdec
      if( i1hashdec .ne. i1Dec8BitBytes(10) ) then
        nbadhash=nbadhash+1
        nhashflag=1   
      endif

! check the message plus hash against what was sent
      do i=1,K
        if( message(i) .ne. decoded(i) ) then
          nueflag=1
        endif
      enddo

      if( nhashflag .eq. 0 .and. nueflag .eq. 0 ) then
        ngood=ngood+1
      else if( nhashflag .eq. 0 .and. nueflag .eq. 1 ) then
        nue=nue+1;
      endif
    endif

  enddo

  write(*,"(f4.1,1x,i8,1x,i8,1x,i8)") db,ngood,nue,nbadhash

enddo

end program ldpcsim
