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

#include "factor_iface.hxx"
#include "factor.hxx"

namespace spral { namespace ssids { namespace cpu {

/** Class representing a subtree to be factored on the CPU */
template <bool posdef, size_t BLOCK_SIZE, typename T, typename StackAllocator>
class CpuSubtree {
public:
   /** Constructor does analyse phase work */
   CpuSubtree(int nnodes, struct cpu_node_data<T>* nodes)
   : nnodes_(nnodes), nodes_(nodes)
   {}
   void factor(T const* aval, T const* scaling, void *const alloc, StackAllocator &stalloc_odd, StackAllocator &stalloc_even, Workspace<T> &work, int* map, struct cpu_factor_options const* options, struct cpu_factor_stats* stats) {
      /* Main loop: Iterate over nodes in order */
      for(int ni=0; ni<nnodes_; ++ni) {
         // Assembly
         assemble_node
            (posdef, ni, &nodes_[ni], alloc, &stalloc_odd, &stalloc_even, map,
             aval, scaling);
         // Update stats
         int nrow = nodes_[ni].nrow_expected + nodes_[ni].ndelay_in;
         stats->maxfront = std::max(stats->maxfront, nrow);
         // Factorization
         factor_node
            <posdef, T, BLOCK_SIZE>
            (ni, &nodes_[ni], options, stats);
         // Form update
         calculate_update<posdef>
            (&nodes_[ni], &stalloc_odd, &stalloc_even, &work);
      }

      // Count stats
      // FIXME: gross hack for compat with bub (which needs to differentiate
      // between a natural zero and a 2x2 factor's second entry without counting)
      // SSIDS original data format [a11 a21 a22 xxx] seems more bizzare than
      // bub one [a11 a21 inf a22]
      if(posdef) {
         // no real changes to stats from zero initialization
      } else { // indefinite
         for(int ni=0; ni<nnodes_; ni++) {
            int m = nodes_[ni].nrow_expected + nodes_[ni].ndelay_in;
            int n = nodes_[ni].ncol_expected + nodes_[ni].ndelay_in;
            T *d = nodes_[ni].lcol + m*n;
            for(int i=0; i<nodes_[ni].nelim; i++)
               if(d[2*i] == std::numeric_limits<T>::infinity())
                  d[2*i] = d[2*i+1];
            for(int i=0; i<nodes_[ni].nelim; ) {
               T a11 = d[2*i];
               T a21 = d[2*i+1];
               if(a21 == 0.0) {
                  // 1x1 pivot (or zero)
                  if(a11 == 0.0) stats->num_zero++;
                  if(a11 < 0.0) stats->num_neg++;
                  i++;
               } else {
                  // 2x2 pivot
                  T a22 = d[2*(i+1)];
                  stats->num_two++;
                  T det = a11*a22 - a21*a21; // product of evals
                  T trace = a11 + a22; // sum of evals
                  if(det < 0) stats->num_neg++;
                  else if(trace < 0) stats->num_neg+=2;
                  i+=2;
               }
            }
         }
      }
   }
   void solve_fwd() {}
   void solve_diag() {}
   void solve_bwd() {}
private:
   int nnodes_;
   struct cpu_node_data<T>* nodes_;
};

}}} /* end of namespace spral::ssids::cpu */