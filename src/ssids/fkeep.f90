!
! This module defines ssids_fkeep type and associated procedures (CPU version)
!
module spral_ssids_fkeep
   use spral_ssids_akeep, only : ssids_akeep_base
   use spral_ssids_datatypes
   use spral_ssids_alloc, only : smfreeall
   use spral_ssids_datatypes, only : long, node_type, smalloc_type, &
                                     ssids_options, wp, SSIDS_ERROR_ALLOCATION,&
                                     SSIDS_SOLVE_JOB_ALL, SSIDS_SOLVE_JOB_BWD, &
                                     SSIDS_SOLVE_JOB_DIAG, SSIDS_SOLVE_JOB_FWD,&
                                     SSIDS_SOLVE_JOB_DIAG_BWD
   use spral_ssids_inform, only : ssids_inform_base
   use spral_ssids_solve_cpu, only : fwd_diag_solve, subtree_bwd_solve
   use spral_ssids_factor_cpu_iface, only : cpu_node_data, cpu_factor_options, &
      cpu_factor_stats, setup_cpu_data, extract_cpu_data, factor_cpu
   use, intrinsic :: iso_c_binding
   implicit none

   private
   public :: ssids_fkeep_base

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   !
   ! Data type for data generated in factorise phase
   !
   type ssids_fkeep_base
      integer :: flag ! copy of error flag.
      real(wp), dimension(:), allocatable :: scaling ! Stores scaling for
         ! each entry (in original matrix order)
      type(node_type), dimension(:), allocatable :: nodes ! Stores pointers
         ! to information about nodes
      type(smalloc_type), pointer :: alloc=>null() ! Linked list of memory pages
         ! pointed to by nodes variable
      logical :: pos_def ! set to true if user indicates matrix pos. definite

      ! Info components to copy on solve
      integer :: matrix_rank
      integer :: maxfront
      integer :: num_delay
      integer(long) :: num_factor
      integer(long) :: num_flops
      integer :: num_neg
      integer :: num_two

   contains
      procedure, pass(fkeep) :: inner_factor => inner_factor_cpu ! Do actual factorization
      procedure, pass(fkeep) :: inner_solve => inner_solve_cpu ! Do actual solve
      procedure, pass(fkeep) :: enquire_posdef => enquire_posdef_cpu
      procedure, pass(fkeep) :: enquire_indef => enquire_indef_cpu
      procedure, pass(fkeep) :: alter => alter_cpu ! Alter D values
      procedure, pass(fkeep) :: free => free_fkeep ! Frees memory
   end type ssids_fkeep_base

contains

subroutine inner_factor_cpu(fkeep, akeep, val, options, inform)
   class(ssids_akeep_base), intent(in) :: akeep
   class(ssids_fkeep_base), target, intent(inout) :: fkeep
   real(wp), dimension(*), target, intent(in) :: val
   class(ssids_options), intent(in) :: options
   class(ssids_inform_base), intent(inout) :: inform

   logical(C_BOOL) :: fposdef
   type(cpu_node_data), dimension(:), allocatable :: cnodes
   type(cpu_factor_options) :: coptions
   type(cpu_factor_stats) :: cstats

   integer :: st

   ! Allocate cnodes and setup for main call
   allocate(cnodes(akeep%nnodes+1), stat=st)
   if(st.ne.0) then
      inform%flag = SSIDS_ERROR_ALLOCATION
      inform%stat = st
      return
   endif
   call setup_cpu_data(akeep, cnodes, options, coptions)

   ! Perform factorization in C++ code
   fposdef = fkeep%pos_def
   if(allocated(fkeep%scaling)) then
      call factor_cpu(fposdef, akeep%n, akeep%nnodes, cnodes, val, &
         C_LOC(fkeep%scaling), C_LOC(fkeep%alloc), coptions, cstats)
   else
      call factor_cpu(fposdef, akeep%n, akeep%nnodes, cnodes, val, &
         C_NULL_PTR, C_LOC(fkeep%alloc), coptions, cstats)
   endif

   ! Gather information back to Fortran
   call extract_cpu_data(cstats, inform)

end subroutine inner_factor_cpu

subroutine inner_solve_cpu(local_job, nrhs, x, ldx, akeep, fkeep, options, inform)
   class(ssids_akeep_base), intent(in) :: akeep
   class(ssids_fkeep_base), intent(inout) :: fkeep
   integer, intent(inout) :: local_job
   integer, intent(in) :: nrhs
   integer, intent(in) :: ldx
   real(wp), dimension(ldx,nrhs), target, intent(inout) :: x
   type(ssids_options), intent(in) :: options
   class(ssids_inform_base), intent(inout) :: inform

   integer :: i, r
   integer :: n

   n = akeep%n

   if (allocated(fkeep%scaling)) then
      if (local_job == SSIDS_SOLVE_JOB_ALL .or. &
            local_job == SSIDS_SOLVE_JOB_FWD) then
         do r = 1, nrhs
            !x(1:n,r) = x(1:n,r) * fkeep%scaling(1:n)
            do i = 1, n
               x(akeep%invp(i),r) = x(akeep%invp(i),r) * fkeep%scaling(i)
            end do
         end do
      end if
   end if

   ! Perform supernodal forward solve or diagonal solve (both in serial)
   call fwd_diag_solve(fkeep%pos_def, local_job, akeep%nnodes, &
      fkeep%nodes, akeep%sptr, akeep%rptr, akeep%rlist, akeep%invp, nrhs, &
      x, ldx, inform%stat)
   if (inform%stat .ne. 0) goto 100

   if( local_job.eq.SSIDS_SOLVE_JOB_DIAG_BWD .or. &
         local_job.eq.SSIDS_SOLVE_JOB_BWD .or. &
         local_job.eq.SSIDS_SOLVE_JOB_ALL ) then
      call subtree_bwd_solve(akeep%nnodes, 1, local_job, fkeep%pos_def,  &
         akeep%nnodes, fkeep%nodes, akeep%sptr, akeep%rptr, akeep%rlist, &
         akeep%invp, nrhs, x, ldx, inform%stat)
   end if
   if (inform%stat .ne. 0) goto 100

   if (allocated(fkeep%scaling)) then
      if (local_job == SSIDS_SOLVE_JOB_ALL .or. &
            local_job == SSIDS_SOLVE_JOB_BWD .or. &
            local_job == SSIDS_SOLVE_JOB_DIAG_BWD) then
         do r = 1, nrhs
            !x(1:n,r) = x(1:n,r) * fkeep%scaling(1:n)
            do i = 1, n
               x(akeep%invp(i),r) = x(akeep%invp(i),r) * fkeep%scaling(i)
            end do
         end do
      end if
   end if

   return

   100 continue
   inform%flag = SSIDS_ERROR_ALLOCATION
   return

end subroutine inner_solve_cpu

!****************************************************************************

subroutine enquire_posdef_cpu(akeep, fkeep, inform, d)
   class(ssids_akeep_base), intent(in) :: akeep
   class(ssids_fkeep_base), target, intent(in) :: fkeep
   class(ssids_inform_base), intent(inout) :: inform
   real(wp), dimension(*), intent(out) :: d

   integer :: blkn, blkm
   integer(long) :: i
   integer :: j
   integer :: n
   integer :: node
   integer :: piv

   type(node_type), pointer :: nptr

   n = akeep%n
   ! ensure d is not returned undefined
   d(1:n) = 0.0 ! ensure do not returned with this undefined
   
   piv = 1
   do node = 1, akeep%nnodes
      nptr => fkeep%nodes(node)
      blkn = akeep%sptr(node+1) - akeep%sptr(node)
      blkm = int(akeep%rptr(node+1) - akeep%rptr(node))
      i = 1
      do j = 1, blkn
         d(piv) = nptr%lcol(i)
         i = i + blkm + 1
         piv = piv + 1
      end do
   end do
end subroutine enquire_posdef_cpu

!****************************************************************************

subroutine enquire_indef_cpu(akeep, fkeep, inform, piv_order, d)
   class(ssids_akeep_base), intent(in) :: akeep
   class(ssids_fkeep_base), target, intent(in) :: fkeep
   class(ssids_inform_base), intent(inout) :: inform
   integer, dimension(*), optional, intent(out) :: piv_order
      ! If i is used to index a variable, its position in the pivot sequence
      ! will be placed in piv_order(i), with its sign negative if it is
      ! part of a 2 x 2 pivot; otherwise, piv_order(i) will be set to zero.
   real(wp), dimension(2,*), optional, intent(out) :: d ! The diagonal
      ! entries of D^{-1} will be placed in d(1,:i) and the off-diagonal
      ! entries will be placed in d(2,:). The entries are held in pivot order.

   integer :: blkn, blkm
   integer :: j, k
   integer :: n
   integer :: nd
   integer :: node
   integer(long) :: offset
   integer :: piv

   type(node_type), pointer :: nptr

   n = akeep%n
   if(present(d)) then
      ! ensure d is not returned undefined
      d(1:2,1:n) = 0.0
   end if
   
   piv = 1
   do node = 1, akeep%nnodes
      nptr => fkeep%nodes(node)
      j = 1
      nd = nptr%ndelay
      blkn = akeep%sptr(node+1) - akeep%sptr(node) + nd
      blkm = int(akeep%rptr(node+1) - akeep%rptr(node)) + nd
      offset = blkm*(blkn+0_long)
      do while(j .le. nptr%nelim)
         if (nptr%lcol(offset+2*j).ne.0) then
            ! 2x2 pivot
            if(present(piv_order))  then
               k = akeep%invp( nptr%perm(j) )
               piv_order(k) = -piv
               k = akeep%invp( nptr%perm(j+1) )
               piv_order(k) = -(piv+1)
            end if
            if(present(d)) then
               d(1,piv) = nptr%lcol(offset+2*j-1)
               d(2,piv) = nptr%lcol(offset+2*j)
               d(1,piv+1) = nptr%lcol(offset+2*j+1)
               d(2,piv+1) = 0
            end if
            piv = piv + 2
            j = j + 2
         else
            ! 1x1 pivot
            if(present(piv_order)) then
               k = akeep%invp( nptr%perm(j) )
               piv_order(k) = piv
            end if
            if(present(d)) then
               d(1,piv) = nptr%lcol(offset+2*j-1)
               d(2,piv) = 0
            end if
            piv = piv + 1
            j = j + 1
         end if
      end do
   end do

end subroutine enquire_indef_cpu

! Alter D values
subroutine alter_cpu(d, akeep, fkeep, options, inform)
   real(wp), dimension(2,*), intent(in) :: d  ! The required diagonal entries
     ! of D^{-1} must be placed in d(1,i) (i = 1,...n)
     ! and the off-diagonal entries must be placed in d(2,i) (i = 1,...n-1).
   type(ssids_akeep_base), intent(in) :: akeep
   class(ssids_fkeep_base), target, intent(inout) :: fkeep
   type(ssids_options), intent(in) :: options
   class(ssids_inform_base), intent(inout) :: inform

   integer :: blkm, blkn
   integer(long) :: ip
   integer :: j
   integer :: nd
   integer :: node
   integer :: piv

   type(node_type), pointer :: nptr

   piv = 1
   do node = 1, akeep%nnodes
      nptr => fkeep%nodes(node)
      nd = nptr%ndelay
      blkn = akeep%sptr(node+1) - akeep%sptr(node) + nd
      blkm = int(akeep%rptr(node+1) - akeep%rptr(node)) + nd
      ip = blkm*(blkn+0_long) + 1
      do j = 1, nptr%nelim
         nptr%lcol(ip)   = d(1,piv)
         nptr%lcol(ip+1) = d(2,piv)
         ip = ip + 2
         piv = piv + 1
      end do
   end do
end subroutine alter_cpu

!****************************************************************************

subroutine free_fkeep(fkeep, flag)
   class(ssids_fkeep_base), intent(inout) :: fkeep
   integer, intent(out) :: flag ! not actually used for cpu version, set to 0

   integer :: st

   flag = 0 ! Not used for basic SSIDS, just zet to zero

   ! Skip if nothing intialized
   if (.not.allocated(fkeep%nodes)) return

   ! Free memory
   call smfreeall(fkeep%alloc)
   deallocate(fkeep%alloc)
   nullify(fkeep%alloc)

   deallocate(fkeep%nodes, stat=st)
   deallocate(fkeep%scaling, stat=st)

end subroutine free_fkeep

end module spral_ssids_fkeep