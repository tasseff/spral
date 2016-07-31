/* Copyright 2016 The Science and Technology Facilities Council (STFC)
 *
 * Authors: Jonathan Hogg (STFC)
 *
 * IMPORTANT: This file is NOT licenced under the BSD licence. If you wish to
 * licence this code, please contact STFC via hsl@stfc.ac.uk
 * (We are currently deciding what licence to release this code under if it
 * proves to be useful beyond our own academic experiments)
 *
 */
#pragma once

/* Standard headers */
#include <cmath>
#include <cstddef>
#include <sstream>
#include <stdexcept>
#include <omp.h>
/* SPRAL headers */
#include "cpu_iface.hxx"
#include "kernels/assemble.hxx"
#include "kernels/calc_ld.hxx"
#include "kernels/cholesky.hxx"
#include "kernels/ldlt_app.hxx"
#include "kernels/ldlt_tpp.hxx"
#include "kernels/wrappers.hxx"
#include "SymbolicNode.hxx"

#include "profile.hxx"

//#include "kernels/verify.hxx" // FIXME: remove debug

namespace spral { namespace ssids { namespace cpu {

const int SSIDS_SUCCESS = 0;
const int SSIDS_ERROR_NOT_POS_DEF = -6;

/** A Workspace is a chunk of memory that can be reused. The get_ptr<T>(len)
 * function provides a pointer to it after ensuring it is of at least the
 * given size. */
class Workspace {
   static int const align = 32;
public:
   Workspace(size_t sz)
   {
      alloc_and_align(sz);
   }
   ~Workspace() {
      ::operator delete(mem_);
   }
   void alloc_and_align(size_t sz) {
      sz_ = sz+align;
      mem_ = ::operator new(sz_);
      mem_aligned_ = mem_;
      std::align(align, sz, mem_aligned_, sz_);
   }
   template <typename T>
   T* get_ptr(size_t len) {
      if(sz_ < len*sizeof(T)) {
         // Need to resize
         ::operator delete(mem_);
         alloc_and_align(len*sizeof(T));
      }
      return static_cast<T*>(mem_aligned_);
   }
private:
   void* mem_;
   void* mem_aligned_;
   size_t sz_;
};

/* Factorize a node (indef) */
template <typename T, typename ContribAlloc>
void factor_node_indef(
      int ni, // FIXME: remove post debug
      SymbolicNode const& snode,
      NumericNode<T>* node,
      struct cpu_factor_options const& options,
      struct cpu_factor_stats& stats,
      Workspace& work,
      ContribAlloc& contrib_alloc
      ) {
   /* Extract useful information about node */
   int m = snode.nrow + node->ndelay_in;
   int n = snode.ncol + node->ndelay_in;
   size_t ldl = align_lda<T>(m);
   T *lcol = node->lcol;
   T *d = &node->lcol[ n*ldl ];
   int *perm = node->perm;
   T *contrib = node->contrib;

   /* Perform factorization */
   //Verify<T> verifier(m, n, perm, lcol, ldl);
   node->nelim = ldlt_app_factor(
         m, n, perm, lcol, ldl, d, 0.0, contrib, m-n, options
         );
   //verifier.verify(node->nelim, perm, lcol, ldl, d);

   /* Finish factorization worth simplistic code */
   if(node->nelim < n) {
#ifdef PROFILE
      Profile::Task task_tpp("TA_LDLT_TPP", omp_get_thread_num());
#endif
      int nelim = node->nelim;
      stats.not_first_pass += n-nelim;
      T *ld = work.get_ptr<T>(2*(m-nelim));
      node->nelim += ldlt_tpp_factor(
            m-nelim, n-nelim, &perm[nelim], &lcol[nelim*(ldl+1)], ldl,
            &d[2*nelim], ld, m-nelim, options.u, options.small, nelim,
            &lcol[nelim], ldl
            );
      if(m-n>0 && node->nelim>nelim) {
         int nelim2 = node->nelim - nelim;
         int ldld = align_lda<T>(m-n);
         T *ld = work.get_ptr<T>(nelim2*ldld);
         calcLD<OP_N>(
               m-n, nelim2, &lcol[nelim*ldl+n], ldl, &d[2*nelim], ld, ldld
               );
         T rbeta = (nelim==0) ? 0.0 : 1.0;
         host_gemm<T>(OP_N, OP_T, m-n, m-n, nelim2,
               -1.0, &lcol[nelim*ldl+n], ldl, ld, ldld,
               rbeta, node->contrib, m-n);
      }
      stats.not_second_pass += n - node->nelim;
#ifdef profile
      task_tpp.done();
#endif
   }

#ifdef PROFILE
      Profile::setState("TA_MISC1", omp_get_thread_num());
#endif
   /* Record information */
   node->ndelay_out = n - node->nelim;
   stats.num_delay += node->ndelay_out;

   /* Mark as no contribution if we make no contribution */
   if(node->nelim==0 && !node->first_child) {
      // FIXME: Actually loop over children and check one exists with contrib
      //        rather than current approach of just looking for children.
      typedef std::allocator_traits<ContribAlloc> CATraits;
      CATraits::deallocate(contrib_alloc, node->contrib, (m-n)*(m-n));
      node->contrib = nullptr;
   } else if(node->nelim==0) {
      // FIXME: If we fix the above, we don't need this explict zeroing
      long contrib_size = m-n;
      memset(node->contrib, 0, contrib_size*contrib_size*sizeof(T));
   }
}
/* Factorize a node (posdef) */
template <typename T>
void factor_node_posdef(
      T beta,
      SymbolicNode const& snode,
      NumericNode<T>* node,
      struct cpu_factor_options const& options,
      struct cpu_factor_stats& stats
      ) {
   /* Extract useful information about node */
   int m = snode.nrow;
   int n = snode.ncol;
   int ldl = align_lda<T>(m);
   T *lcol = node->lcol;
   T *contrib = node->contrib;

   /* Perform factorization */
   int flag;
   cholesky_factor(
         m, n, lcol, ldl, beta, contrib, m-n, options.cpu_task_block_size, &flag
         );
   #pragma omp taskwait
   if(flag!=-1) {
      node->nelim = flag+1;
      stats.flag = SSIDS_ERROR_NOT_POS_DEF;
      return;
   }
   node->nelim = n;

   /* Record information */
   node->ndelay_out = 0;
}
/* Factorize a node (wrapper) */
template <bool posdef, typename T, typename ContribAlloc>
void factor_node(
      int ni,
      SymbolicNode const& snode,
      NumericNode<T>* node,
      struct cpu_factor_options const& options,
      struct cpu_factor_stats& stats,
      Workspace& work,
      ContribAlloc& contrib_alloc,
      T beta=0.0 // FIXME: remove once smallleafsubtree is doing own thing
      ) {
   if(posdef) factor_node_posdef<T>(beta, snode, node, options, stats);
   else       factor_node_indef <T>(ni, snode, node, options, stats, work, contrib_alloc);
}

}}} /* end of namespace spral::ssids::cpu */
