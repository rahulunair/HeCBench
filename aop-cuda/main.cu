/* Copyright (c) 2014, NVIDIA CORPORATION. All rights reserved.
 *
   redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
 
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <random>
#include <chrono>
#include <algorithm>
#include <cuda.h>

#ifdef WITH_FULL_W_MATRIX
#define R_W_MATRICES_SMEM_SLOTS 15
#else
#define R_W_MATRICES_SMEM_SLOTS 12
#endif

#define CHECK_CUDA(call) do { \
  cudaError_t status = call; \
  if( status != cudaSuccess ) { \
    fprintf(stderr, "CUDA Error at line %d in %s: %s\n", __LINE__, __FILE__, cudaGetErrorString(status)); \
    exit((int) status); \
  } \
} while(0)

#define HOST_DEVICE        __host__ __device__
#define HOST_DEVICE_INLINE __host__ __device__ __forceinline__

HOST_DEVICE_INLINE double3 operator+(const double3 &u, const double3 &v )
{
  return make_double3(u.x+v.x, u.y+v.y, u.z+v.z);
}

HOST_DEVICE_INLINE double4 operator+(const double4 &u, const double4 &v )
{
  return make_double4(u.x+v.x, u.y+v.y, u.z+v.z, u.w+v.w);
}

struct PayoffCall
{
  double m_K;
  HOST_DEVICE_INLINE PayoffCall(double K) : m_K(K) {}
  HOST_DEVICE_INLINE double operator()(double S) const { return fmax(S - m_K, 0.0); }
  HOST_DEVICE_INLINE int is_in_the_money(double S) const { return S > m_K; }
};

struct PayoffPut
{
  double m_K;
  HOST_DEVICE_INLINE PayoffPut(double K) : m_K(K) {}
  HOST_DEVICE_INLINE double operator()(double S) const { return fmax(m_K - S, 0.0); }
  HOST_DEVICE_INLINE int is_in_the_money(double S) const { return S < m_K; }
};


template< int NUM_THREADS_PER_BLOCK, typename Payoff >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK)
void generate_paths_kernel(int num_timesteps, 
                           int num_paths, 
                           Payoff payoff,
                           double dt, 
                           double S0, 
                           double r, 
                           double sigma, 
                           const double *__restrict samples, 
                           double *__restrict paths)
{
  // The path generated by this thread.
  int path = blockIdx.x*NUM_THREADS_PER_BLOCK + threadIdx.x;

  // Early exit.
  if( path >= num_paths ) return;
  
  // Compute (r - sigma^2 / 2).
  const double r_min_half_sigma_sq_dt = (r - 0.5*sigma*sigma)*dt;
  // Compute sigma*sqrt(dt).
  const double sigma_sqrt_dt = sigma*sqrt(dt);

  // Keep the previous price.
  double S = S0;

  // The offset.
  int offset = path;
  
  // Each thread generates several timesteps. 
  for( int timestep = 0 ; timestep < num_timesteps-1 ; ++timestep, offset += num_paths )
  {
    S = S * exp(r_min_half_sigma_sq_dt + sigma_sqrt_dt*samples[offset]);
    paths[offset] = S;
  }

  // The asset price.
  S = S * exp(r_min_half_sigma_sq_dt + sigma_sqrt_dt*samples[offset]);

  // Store the payoff at expiry.
  paths[offset] = payoff(S);
}

static __device__ __forceinline__ void assemble_R(int m, double4 &sums, double *smem_svds)
{
  // Assemble R.

  double x0 = smem_svds[0];
  double x1 = smem_svds[1];
  double x2 = smem_svds[2];

  double x0_sq = x0 * x0;

  double sum1 = sums.x - x0;
  double sum2 = sums.y - x0_sq;
  double sum3 = sums.z - x0_sq*x0;
  double sum4 = sums.w - x0_sq*x0_sq;

  double m_as_dbl = (double) m;
  double sigma = m_as_dbl - 1.0;
  double mu = sqrt(m_as_dbl);
  double v0 = -sigma / (1.0 + mu);
  double v0_sq = v0*v0;
  double beta = 2.0 * v0_sq / (sigma + v0_sq);
  
  double inv_v0 = 1.0 / v0;
  double one_min_beta = 1.0 - beta;
  double beta_div_v0  = beta * inv_v0;
  
  smem_svds[0] = mu;
  smem_svds[1] = one_min_beta*x0 - beta_div_v0*sum1;
  smem_svds[2] = one_min_beta*x0_sq - beta_div_v0*sum2;
  
  // Rank update coefficients.
  
  double beta_div_v0_sq = beta_div_v0 * inv_v0;
  
  double c1 = beta_div_v0_sq*sum1 + beta_div_v0*x0;
  double c2 = beta_div_v0_sq*sum2 + beta_div_v0*x0_sq;

  // 2nd step of QR.
  
  double x1_sq = x1*x1;

  sum1 -= x1;
  sum2 -= x1_sq;
  sum3 -= x1_sq*x1;
  sum4 -= x1_sq*x1_sq;
  
  x0 = x1-c1;
  x0_sq = x0*x0;
  sigma = sum2 - 2.0*c1*sum1 + (m_as_dbl-2.0)*c1*c1;
  if( abs(sigma) < 1.0e-16 )
    beta = 0.0;
  else
  {
    mu = sqrt(x0_sq + sigma);
    if( x0 <= 0.0 )
      v0 = x0 - mu;
    else
      v0 = -sigma / (x0 + mu);
    v0_sq = v0*v0;
    beta = 2.0*v0_sq / (sigma + v0_sq);
  }
  
  inv_v0 = 1.0 / v0;
  beta_div_v0 = beta * inv_v0;
  
  // The coefficient to perform the rank update.
  double c3 = (sum3 - c1*sum2 - c2*sum1 + (m_as_dbl-2.0)*c1*c2)*beta_div_v0;
  double c4 = (x1_sq-c2)*beta_div_v0 + c3*inv_v0;
  double c5 = c1*c4 - c2;
  
  one_min_beta = 1.0 - beta;
  
  // Update R. 
  smem_svds[3] = one_min_beta*x0 - beta_div_v0*sigma;
  smem_svds[4] = one_min_beta*(x1_sq-c2) - c3;
  
  // 3rd step of QR.
  
  double x2_sq = x2*x2;

  sum1 -= x2;
  sum2 -= x2_sq;
  sum3 -= x2_sq*x2;
  sum4 -= x2_sq*x2_sq;
  
  x0 = x2_sq-c4*x2+c5;
  sigma = sum4 - 2.0*c4*sum3 + (c4*c4 + 2.0*c5)*sum2 - 2.0*c4*c5*sum1 + (m_as_dbl-3.0)*c5*c5;
  if( abs(sigma) < 1.0e-12 )
    beta = 0.0;
  else
  {
    mu = sqrt(x0*x0 + sigma);
    if( x0 <= 0.0 )
      v0 = x0 - mu;
    else
      v0 = -sigma / (x0 + mu);
    v0_sq = v0*v0;
    beta = 2.0*v0_sq / (sigma + v0_sq);
  }
  
  // Update R.
  smem_svds[5] = (1.0-beta)*x0 - (beta/v0)*sigma;
}

static __host__ __device__ double off_diag_norm(double A01, double A02, double A12)
{
  return sqrt(2.0 * (A01*A01 + A02*A02 + A12*A12));
}

static __device__ __forceinline__ void swap(double &x, double &y)
{
  double t = x; x = y; y = t;
}

static __device__ __forceinline__ void svd_3x3(int m, double4 &sums, double *smem_svds)
{
  // Assemble the R matrix.
  assemble_R(m, sums, smem_svds);

  // The matrix R.
  double R00 = smem_svds[0];
  double R01 = smem_svds[1];
  double R02 = smem_svds[2];
  double R11 = smem_svds[3];
  double R12 = smem_svds[4];
  double R22 = smem_svds[5];

  // We compute the eigenvalues/eigenvectors of A = R^T R.
  
  double A00 = R00*R00;
  double A01 = R00*R01;
  double A02 = R00*R02;
  double A11 = R01*R01 + R11*R11;
  double A12 = R01*R02 + R11*R12;
  double A22 = R02*R02 + R12*R12 + R22*R22;
  
  // We keep track of V since A = Sigma^2 V. Each thread stores a row of V.
  
  double V00 = 1.0, V01 = 0.0, V02 = 0.0;
  double V10 = 0.0, V11 = 1.0, V12 = 0.0;
  double V20 = 0.0, V21 = 0.0, V22 = 1.0;
  
  // The Jacobi algorithm is iterative. We fix the max number of iter and the minimum tolerance.
  
  const int max_iters = 16;
  const double tolerance = 1.0e-12;
  
  // Iterate until we reach the max number of iters or the tolerance.
 
  for( int iter = 0 ; off_diag_norm(A01, A02, A12) >= tolerance && iter < max_iters ; ++iter )
  {
    double c, s, B00, B01, B02, B10, B11, B12, B20, B21, B22;
    
    // Compute the Jacobi matrix for p=0 and q=1.
    
    c = 1.0, s = 0.0;
    if( A01 != 0.0 )
    {
      double tau = (A11 - A00) / (2.0 * A01);
      double sgn = tau < 0.0 ? -1.0 : 1.0;
      double t   = sgn / (sgn*tau + sqrt(1.0 + tau*tau));
      
      c = 1.0 / sqrt(1.0 + t*t);
      s = t*c;
    }
    
    // Update A = J^T A J and V = V J.
    
    B00 = c*A00 - s*A01;
    B01 = s*A00 + c*A01;
    B10 = c*A01 - s*A11;
    B11 = s*A01 + c*A11;
    B02 = A02;
    
    A00 = c*B00 - s*B10;
    A01 = c*B01 - s*B11;
    A11 = s*B01 + c*B11;
    A02 = c*B02 - s*A12;
    A12 = s*B02 + c*A12;
    
    B00 = c*V00 - s*V01;
    V01 = s*V00 + c*V01;
    V00 = B00;
    
    B10 = c*V10 - s*V11;
    V11 = s*V10 + c*V11;
    V10 = B10;
    
    B20 = c*V20 - s*V21;
    V21 = s*V20 + c*V21;
    V20 = B20;
    
    // Compute the Jacobi matrix for p=0 and q=2.
    
    c = 1.0, s = 0.0;
    if( A02 != 0.0 )
    {
      double tau = (A22 - A00) / (2.0 * A02);
      double sgn = tau < 0.0 ? -1.0 : 1.0;
      double t   = sgn / (sgn*tau + sqrt(1.0 + tau*tau));
      
      c = 1.0 / sqrt(1.0 + t*t);
      s = t*c;
    }
    
    // Update A = J^T A J and V = V J.
    
    B00 = c*A00 - s*A02;
    B01 = c*A01 - s*A12;
    B02 = s*A00 + c*A02;
    B20 = c*A02 - s*A22;
    B22 = s*A02 + c*A22;
    
    A00 = c*B00 - s*B20;
    A12 = s*A01 + c*A12;
    A02 = c*B02 - s*B22;
    A22 = s*B02 + c*B22;
    A01 = B01;
    
    B00 = c*V00 - s*V02;
    V02 = s*V00 + c*V02;
    V00 = B00;
    
    B10 = c*V10 - s*V12;
    V12 = s*V10 + c*V12;
    V10 = B10;
    
    B20 = c*V20 - s*V22;
    V22 = s*V20 + c*V22;
    V20 = B20;
    
    // Compute the Jacobi matrix for p=1 and q=2.
    
    c = 1.0, s = 0.0;
    if( A12 != 0.0 )
    {
      double tau = (A22 - A11) / (2.0 * A12);
      double sgn = tau < 0.0 ? -1.0 : 1.0;
      double t   = sgn / (sgn*tau + sqrt(1.0 + tau*tau));
      
      c = 1.0 / sqrt(1.0 + t*t);
      s = t*c;
    }
    
    // Update A = J^T A J and V = V J.
    
    B02 = s*A01 + c*A02;
    B11 = c*A11 - s*A12;
    B12 = s*A11 + c*A12;
    B21 = c*A12 - s*A22;
    B22 = s*A12 + c*A22;
    
    A01 = c*A01 - s*A02;
    A02 = B02;
    A11 = c*B11 - s*B21;
    A12 = c*B12 - s*B22;
    A22 = s*B12 + c*B22;
    
    B01 = c*V01 - s*V02;
    V02 = s*V01 + c*V02;
    V01 = B01;
    
    B11 = c*V11 - s*V12;
    V12 = s*V11 + c*V12;
    V11 = B11;
    
    B21 = c*V21 - s*V22;
    V22 = s*V21 + c*V22;
    V21 = B21;
  }

  // Swap the columns to have S[0] >= S[1] >= S[2].
  if( A00 < A11 )
  {
    swap(A00, A11);
    swap(V00, V01);
    swap(V10, V11);
    swap(V20, V21);
  }
  if( A00 < A22 )
  {
    swap(A00, A22);
    swap(V00, V02);
    swap(V10, V12);
    swap(V20, V22);
  }
  if( A11 < A22 )
  {
    swap(A11, A22);
    swap(V01, V02);
    swap(V11, V12);
    swap(V21, V22);
  }

  //printf("timestep=%3d, svd0=%.8lf svd1=%.8lf svd2=%.8lf\n", blockIdx.x, sqrt(A00), sqrt(A11), sqrt(A22));
  
  // Invert the diagonal terms and compute V*S^-1.
  
  double inv_S0 = abs(A00) < 1.0e-12 ? 0.0 : 1.0 / A00;
  double inv_S1 = abs(A11) < 1.0e-12 ? 0.0 : 1.0 / A11;
  double inv_S2 = abs(A22) < 1.0e-12 ? 0.0 : 1.0 / A22;

  // printf("SVD: timestep=%3d %12.8lf %12.8lf %12.8lf\n", blockIdx.x, sqrt(A00), sqrt(A11), sqrt(A22));
  
  double U00 = V00 * inv_S0; 
  double U01 = V01 * inv_S1; 
  double U02 = V02 * inv_S2;
  double U10 = V10 * inv_S0; 
  double U11 = V11 * inv_S1; 
  double U12 = V12 * inv_S2;
  double U20 = V20 * inv_S0; 
  double U21 = V21 * inv_S1; 
  double U22 = V22 * inv_S2;
  
  // Compute V*S^-1*V^T*R^T.
  
#ifdef WITH_FULL_W_MATRIX
  double B00 = U00*V00 + U01*V01 + U02*V02;
  double B01 = U00*V10 + U01*V11 + U02*V12;
  double B02 = U00*V20 + U01*V21 + U02*V22;
  double B10 = U10*V00 + U11*V01 + U12*V02;
  double B11 = U10*V10 + U11*V11 + U12*V12;
  double B12 = U10*V20 + U11*V21 + U12*V22;
  double B20 = U20*V00 + U21*V01 + U22*V02;
  double B21 = U20*V10 + U21*V11 + U22*V12;
  double B22 = U20*V20 + U21*V21 + U22*V22;
  
  smem_svds[ 6] = B00*R00 + B01*R01 + B02*R02;
  smem_svds[ 7] =           B01*R11 + B02*R12;
  smem_svds[ 8] =                     B02*R22;
  smem_svds[ 9] = B10*R00 + B11*R01 + B12*R02;
  smem_svds[10] =           B11*R11 + B12*R12;
  smem_svds[11] =                     B12*R22;
  smem_svds[12] = B20*R00 + B21*R01 + B22*R02;
  smem_svds[13] =           B21*R11 + B22*R12;
  smem_svds[14] =                     B22*R22;
#else
  double B00 = U00*V00 + U01*V01 + U02*V02;
  double B01 = U00*V10 + U01*V11 + U02*V12;
  double B02 = U00*V20 + U01*V21 + U02*V22;
  double B11 = U10*V10 + U11*V11 + U12*V12;
  double B12 = U10*V20 + U11*V21 + U12*V22;
  double B22 = U20*V20 + U21*V21 + U22*V22;
  
  smem_svds[ 6] = B00*R00 + B01*R01 + B02*R02;
  smem_svds[ 7] =           B01*R11 + B02*R12;
  smem_svds[ 8] =                     B02*R22;
  smem_svds[ 9] =           B11*R11 + B12*R12;
  smem_svds[10] =                     B12*R22;
  smem_svds[11] =                     B22*R22;
#endif
}

template< int NUM_THREADS_PER_BLOCK, typename Payoff >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK, 4)
void prepare_svd_kernel(int num_paths, 
                        int min_in_the_money, 
                        Payoff payoff, 
                        const double *__restrict paths, 
                                 int *__restrict all_out_of_the_money, 
                              double *__restrict svds)
{
  // We need to perform a scan to find the first 3 stocks pay off.
  __shared__ int scan_input[NUM_THREADS_PER_BLOCK];
  __shared__ int scan_output[1+NUM_THREADS_PER_BLOCK];

  // sum reduction
  __shared__ double4 lsums;
  __shared__ int lsum;

  // Shared buffer for the ouput.
  __shared__ double smem_svds[R_W_MATRICES_SMEM_SLOTS];

  // Each block works on a single timestep. 
  const int timestep = blockIdx.x;
  // The timestep offset.
  const int offset = timestep * num_paths;

  // Sums.
  int m = 0; double4 sums = { 0.0, 0.0, 0.0, 0.0 };

  // Initialize the shared memory. DBL_MAX is a marker to specify that the value is invalid.
  if( threadIdx.x < R_W_MATRICES_SMEM_SLOTS )
    smem_svds[threadIdx.x] = 0.0;
  __syncthreads();

  // Have we already found our 3 first paths which pay off.
  int found_paths = 0;

  // Iterate over the paths.
  //for( int path = threadIdx.x ; path < num_paths ; path += NUM_THREADS_PER_BLOCK )
  for( int path = threadIdx.x ; path < num_paths ; path += NUM_THREADS_PER_BLOCK )
  {
    // Load the asset price to determine if it pays off.
    double S = 0.0;
    if( path < num_paths )
      S = paths[offset + path];

    // Check if it pays off.
    const int in_the_money = payoff.is_in_the_money(S);

    // Try to check if we have found the 3 first stocks.
    scan_input[threadIdx.x] = in_the_money;
    __syncthreads();
    if (threadIdx.x == 0) {
      scan_output[0] = 0;
      for (int i = 1; i <= NUM_THREADS_PER_BLOCK; i++) 
        scan_output[i] = scan_output[i-1]+scan_input[i-1];
    }
    __syncthreads();
    const int partial_sum = scan_output[threadIdx.x];
    const int total_sum = scan_output[NUM_THREADS_PER_BLOCK];

    if( found_paths < 3 )
    {
      if( in_the_money && found_paths + partial_sum < 3 )
        smem_svds[found_paths + partial_sum] = S;
      __syncthreads();
      found_paths += total_sum;
    }

    // Early continue if no item pays off.
    if (threadIdx.x == 0) lsum = 0;
    __syncthreads();
    atomicOr(&lsum, in_the_money);
    __syncthreads();
    if (lsum == 0) continue;
    
    // Update the number of payoff items.
    m += in_the_money;

    // The "normalized" value.
    double x = 0.0, x_sq = 0.0;
    if( in_the_money )
    {
      x = S;
      x_sq = S*S;
    }

    // Compute the 4 sums.
    sums.x += x;
    sums.y += x_sq;
    sums.z += x_sq*x;
    sums.w += x_sq*x_sq;
  }

  // Compute the final reductions.
  if (threadIdx.x == 0) lsum = 0;
  __syncthreads();

  atomicAdd(&lsum, m);

  __syncthreads();

  int not_enough_paths = 0;
  // Do we all exit?
  if (threadIdx.x == 0 && lsum < min_in_the_money)
    not_enough_paths = 1;
  
  // Early exit if no path is in the money.
  if( not_enough_paths )
  {
    if( threadIdx.x == 0 )
      all_out_of_the_money[blockIdx.x] = 1;
  } 
  else
  {
    // Compute the final reductions.

    if (threadIdx.x == 0)
      lsums = make_double4(0,0,0,0);
    __syncthreads();

    atomicAdd(&lsums.x, sums.x);
    atomicAdd(&lsums.y, sums.y);
    atomicAdd(&lsums.z, sums.z);
    atomicAdd(&lsums.w, sums.w);
    
    __syncthreads();
    
    // The 1st thread has everything he needs to build R from the QR decomposition.
    if( threadIdx.x == 0 )
      svd_3x3(lsum, lsums, smem_svds);

    __syncthreads();

    // Store the final results.
    if( threadIdx.x < R_W_MATRICES_SMEM_SLOTS )
      svds[16*blockIdx.x + threadIdx.x] = smem_svds[threadIdx.x];
  }
}

template< int NUM_THREADS_PER_BLOCK, typename Payoff >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK, 8)
void compute_partial_beta_kernel(int num_paths,
                                 Payoff payoff,
                                 const double *__restrict svd,
                                 const double *__restrict paths,
                                 const double *__restrict cashflows,
                                 const int *__restrict all_out_of_the_money,
                                 double *__restrict partial_sums)
{
  // The shared memory storage.
  __shared__ double3 lsums;
  
  // The shared memory to store the SVD.
  __shared__ double shared_svd[R_W_MATRICES_SMEM_SLOTS];
    
  // Early exit if needed.
  if( *all_out_of_the_money ) return;

  // The number of threads per grid.
  const int NUM_THREADS_PER_GRID = NUM_THREADS_PER_BLOCK * gridDim.x;

  // The 1st threads loads the matrices SVD and R.
  if( threadIdx.x < R_W_MATRICES_SMEM_SLOTS )
    shared_svd[threadIdx.x] = svd[threadIdx.x];
  __syncthreads();

  // Load the terms of R.
  const double R00 = shared_svd[ 0];
  const double R01 = shared_svd[ 1];
  const double R02 = shared_svd[ 2];
  const double R11 = shared_svd[ 3];
  const double R12 = shared_svd[ 4];
  const double R22 = shared_svd[ 5];

  // Load the elements of W.
#ifdef WITH_FULL_W_MATRIX
  const double W00 = shared_svd[ 6];
  const double W01 = shared_svd[ 7];
  const double W02 = shared_svd[ 8];
  const double W10 = shared_svd[ 9];
  const double W11 = shared_svd[10];
  const double W12 = shared_svd[11];
  const double W20 = shared_svd[12];
  const double W21 = shared_svd[13];
  const double W22 = shared_svd[14];
#else
  const double W00 = shared_svd[ 6];
  const double W01 = shared_svd[ 7];
  const double W02 = shared_svd[ 8];
  const double W11 = shared_svd[ 9];
  const double W12 = shared_svd[10];
  const double W22 = shared_svd[11];
#endif

  // Invert the diagonal of R.
  const double inv_R00 = R00 != 0.0 ? __drcp_rn(R00) : 0.0;
  const double inv_R11 = R11 != 0.0 ? __drcp_rn(R11) : 0.0;
  const double inv_R22 = R22 != 0.0 ? __drcp_rn(R22) : 0.0;

  // Precompute the R terms.
  const double inv_R01 = inv_R00*inv_R11*R01;
  const double inv_R02 = inv_R00*inv_R22*R02;
  const double inv_R12 =         inv_R22*R12;
  
  // Precompute W00/R00.
#ifdef WITH_FULL_W_MATRIX
  const double inv_W00 = W00*inv_R00;
  const double inv_W10 = W10*inv_R00;
  const double inv_W20 = W20*inv_R00;
#else
  const double inv_W00 = W00*inv_R00;
#endif

  // Each thread has 3 numbers to sum.
  double beta0 = 0.0, beta1 = 0.0, beta2 = 0.0;

  // Iterate over the paths.
  for( int path = blockIdx.x*NUM_THREADS_PER_BLOCK + threadIdx.x ; path < num_paths ; path += NUM_THREADS_PER_GRID )
  {
    // Threads load the asset price to rebuild Q from the QR decomposition.
    double S = paths[path];

    // Is the path in the money?
    const int in_the_money = payoff.is_in_the_money(S);

    // Compute Qis. The elements of the Q matrix in the QR decomposition.
    double Q1i = inv_R11*S - inv_R01;
    double Q2i = inv_R22*S*S - inv_R02 - Q1i*inv_R12;

    // Compute the ith row of the pseudo-inverse of [1 X X^2].
#ifdef WITH_FULL_W_MATRIX
    const double WI0 = inv_W00 + W01 * Q1i + W02 * Q2i;
    const double WI1 = inv_W10 + W11 * Q1i + W12 * Q2i;
    const double WI2 = inv_W20 + W21 * Q1i + W22 * Q2i;
#else
    const double WI0 = inv_W00 + W01 * Q1i + W02 * Q2i;
    const double WI1 =           W11 * Q1i + W12 * Q2i;
    const double WI2 =                       W22 * Q2i;
#endif

    // Each thread loads its element from the Y vector.
    double cashflow = in_the_money ? cashflows[path] : 0.0;
  
    // Update beta.
    beta0 += WI0*cashflow;
    beta1 += WI1*cashflow;
    beta2 += WI2*cashflow;
  }

  // Compute the sum of the elements in the block. 
  if( threadIdx.x == 0 )
    lsums = make_double3(0,0,0);
  __syncthreads();

  atomicAdd(&lsums.x, beta0);
  atomicAdd(&lsums.y, beta1);
  atomicAdd(&lsums.z, beta2);
 
  __syncthreads();
  
  // The 1st thread stores the result to GMEM.
  if( threadIdx.x == 0 )
  {
    partial_sums[0*NUM_THREADS_PER_BLOCK + blockIdx.x] = lsums.x;
    partial_sums[1*NUM_THREADS_PER_BLOCK + blockIdx.x] = lsums.y;
    partial_sums[2*NUM_THREADS_PER_BLOCK + blockIdx.x] = lsums.z;
  }
}

template< int NUM_THREADS_PER_BLOCK >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK)
void compute_final_beta_kernel(const int *__restrict all_out_of_the_money, double *__restrict beta)
{
  // The shared memory for the reduction.
  __shared__ double3 lsums;

  // Early exit if needed.
  if( *all_out_of_the_money )
  {
    if( threadIdx.x < 3 )
      beta[threadIdx.x] = 0.0;
    return;
  }

  // The final sums.
  double3 sums;
  
  // We load the elements.
  sums.x = beta[0*NUM_THREADS_PER_BLOCK + threadIdx.x];
  sums.y = beta[1*NUM_THREADS_PER_BLOCK + threadIdx.x];
  sums.z = beta[2*NUM_THREADS_PER_BLOCK + threadIdx.x];
  
  // Compute the sums.
  if( threadIdx.x == 0 )
    lsums = make_double3(0,0,0);
  __syncthreads();

  atomicAdd(&lsums.x, sums.x);
  atomicAdd(&lsums.y, sums.y);
  atomicAdd(&lsums.z, sums.z);
 
  __syncthreads();
  
  // Store beta.
  if( threadIdx.x == 0 )
  {
    //printf("beta0=%.8lf beta1=%.8lf beta2=%.8lf\n", sums.x, sums.y, sums.z);
    beta[0] = lsums.x; 
    beta[1] = lsums.y;
    beta[2] = lsums.z;
  }
}

// assumes beta has been built either by compute_final_beta_kernel or
// by atomic operations at the end of compute_partial_beta_kernel.

template< int NUM_THREADS_PER_BLOCK, typename Payoff >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK)
void update_cashflow_kernel(int num_paths,
                            Payoff payoff_object,
                            double exp_min_r_dt,
                            const double *__restrict beta,
                            const double *__restrict paths,
                            const int *__restrict all_out_of_the_money,
                            double *__restrict cashflows)
{
  const int NUM_THREADS_PER_GRID = gridDim.x * NUM_THREADS_PER_BLOCK;

  // Are we going to skip the computations.
  const int skip_computations = *all_out_of_the_money;

  // Load the beta coefficients for the linear regression.
  const double beta0 = beta[0];
  const double beta1 = beta[1];
  const double beta2 = beta[2];

  // Iterate over the paths.
  int path = blockIdx.x*NUM_THREADS_PER_BLOCK + threadIdx.x;
  for( ; path < num_paths ; path += NUM_THREADS_PER_GRID )
  {
    // The cashflow.
    const double old_cashflow = exp_min_r_dt*cashflows[path];
    if( skip_computations )
    {
      cashflows[path] = old_cashflow;
      continue;
    }
  
    // Load the asset price.
    double S  = paths[path];
    double S2 = S*S;

    // The payoff.
    double payoff = payoff_object(S);

    // Compute the estimated payoff from continuing.
    double estimated_payoff = beta0 + beta1*S + beta2*S2;

    // Discount the payoff because we did not take it into account for beta.
    estimated_payoff *= exp_min_r_dt;

    // Update the payoff.
    if( payoff <= 1.0e-8 || payoff <= estimated_payoff )
      payoff = old_cashflow;
    
    // Store the updated cashflow.
    cashflows[path] = payoff;
  }
}

template< int NUM_THREADS_PER_BLOCK >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK)
void compute_partial_sums_kernel(int num_paths, const double *__restrict cashflows, double *__restrict sums)
{
  // Shared memory to compute the final sum.
  __shared__ double lsum;

  // Each thread works on a single path.
  const int path = blockIdx.x * NUM_THREADS_PER_BLOCK + threadIdx.x;

  // Load the final sum.
  double sum = 0.0;
  if( path < num_paths )
    sum = cashflows[path];

  // Compute the sum over the block.
  if (threadIdx.x == 0)
    lsum = 0;
  __syncthreads();
  
  atomicAdd(&lsum, sum);
  __syncthreads();

  // The block leader writes the sum to GMEM.
  if( threadIdx.x == 0 )
    sums[blockIdx.x] = lsum;
}

template< int NUM_THREADS_PER_BLOCK >
__global__ __launch_bounds__(NUM_THREADS_PER_BLOCK)
void compute_final_sum_kernel(int num_paths, int num_blocks, double exp_min_r_dt, double *__restrict sums)
{
  // Shared memory to compute the final sum.
  __shared__ double lsum;

  // The sum.
  double sum = 0.0;
  for( int item = threadIdx.x ; item < num_blocks ; item += NUM_THREADS_PER_BLOCK )
    sum += sums[item];

  // Compute the sum over the block.
  if (threadIdx.x == 0) lsum = 0;
  __syncthreads();
  
  atomicAdd(&lsum, sum);
  __syncthreads();

  // The block leader writes the sum to GMEM.
  if( threadIdx.x == 0 )
  {
    sums[0] = exp_min_r_dt * lsum / (double) num_paths;
  }
}

template< typename Payoff >
static inline 
void do_run(double *h_samples,
            int num_timesteps, 
            int num_paths, 
            const Payoff &payoff, 
            double dt,
            double S0,
            double r,
            double sigma,
            double *d_samples,
            double *d_paths,
            double *d_cashflows,
            double *d_svds,
            int    *d_all_out_of_the_money,
            double *d_temp_storage,
            double *h_price)
{
  CHECK_CUDA(cudaMemcpy(d_samples, h_samples, sizeof(double) * num_timesteps*num_paths, cudaMemcpyHostToDevice));

  // Generate asset prices.
  const int NUM_THREADS_PER_BLOCK0 = 256;
  int grid_dim = (num_paths + NUM_THREADS_PER_BLOCK0-1) / NUM_THREADS_PER_BLOCK0;
  generate_paths_kernel<NUM_THREADS_PER_BLOCK0><<<grid_dim, NUM_THREADS_PER_BLOCK0>>>(
    num_timesteps,
    num_paths,
    payoff, 
    dt, 
    S0, 
    r, 
    sigma, 
    d_samples,
    d_paths);
  CHECK_CUDA(cudaGetLastError());

  // Reset the all_out_of_the_money array.
  CHECK_CUDA(cudaMemsetAsync(d_all_out_of_the_money, 0, num_timesteps*sizeof(int)));

  // Prepare the SVDs.
  const int NUM_THREADS_PER_BLOCK1 = 256;
  prepare_svd_kernel<NUM_THREADS_PER_BLOCK1><<<num_timesteps-1, NUM_THREADS_PER_BLOCK1>>>(
    num_paths,
    4, //1024,
    payoff, 
    d_paths, 
    d_all_out_of_the_money,
    d_svds);
  CHECK_CUDA(cudaGetLastError());

  // The constant to discount the payoffs.
  const double exp_min_r_dt = std::exp(-r*dt);

  // Number of threads per wave at fully occupancy.
  const int num_threads_per_wave_full_occupancy = 256 * 112;

  // Enable 8B mode for SMEM.
  const int NUM_THREADS_PER_BLOCK2 = 128;

  // Update the cashflows.
  grid_dim = (num_paths + NUM_THREADS_PER_BLOCK2-1) / NUM_THREADS_PER_BLOCK2;
  double num_waves = grid_dim*NUM_THREADS_PER_BLOCK2 / (double) num_threads_per_wave_full_occupancy;

  int update_cashflow_grid = grid_dim;
  if( num_waves < 10 && num_waves - (int) num_waves < 0.6 )
    update_cashflow_grid = std::max(1, (int) num_waves) * num_threads_per_wave_full_occupancy / NUM_THREADS_PER_BLOCK2;

  // Run the main loop.
  for( int timestep = num_timesteps-2 ; timestep >= 0 ; --timestep )
  {
    // Compute beta (two kernels) for that timestep.
    compute_partial_beta_kernel<NUM_THREADS_PER_BLOCK2><<<NUM_THREADS_PER_BLOCK2, NUM_THREADS_PER_BLOCK2>>>(
      num_paths,
      payoff,
      d_svds + 16*timestep,
      d_paths + timestep*num_paths,
      d_cashflows,
      d_all_out_of_the_money + timestep,
      d_temp_storage);
    CHECK_CUDA(cudaGetLastError());

    compute_final_beta_kernel<NUM_THREADS_PER_BLOCK2><<<1, NUM_THREADS_PER_BLOCK2>>>(
      d_all_out_of_the_money + timestep,
      d_temp_storage);
    CHECK_CUDA(cudaGetLastError());

    update_cashflow_kernel<NUM_THREADS_PER_BLOCK2><<<update_cashflow_grid, NUM_THREADS_PER_BLOCK2>>>(
      num_paths,
      payoff,
      exp_min_r_dt,
      d_temp_storage,
      d_paths + timestep*num_paths,
      d_all_out_of_the_money + timestep,
      d_cashflows);
    CHECK_CUDA(cudaGetLastError());
  }

  // Compute the final sum.
  const int NUM_THREADS_PER_BLOCK4 = 128;
  grid_dim = (num_paths + NUM_THREADS_PER_BLOCK4-1) / NUM_THREADS_PER_BLOCK4;
  
  compute_partial_sums_kernel<NUM_THREADS_PER_BLOCK4><<<grid_dim, NUM_THREADS_PER_BLOCK4>>>(
    num_paths,
    d_cashflows,
    d_temp_storage);
  CHECK_CUDA(cudaGetLastError());

  compute_final_sum_kernel<NUM_THREADS_PER_BLOCK4><<<1, NUM_THREADS_PER_BLOCK4>>>(
    num_paths,
    grid_dim,
    exp_min_r_dt,
    d_temp_storage);
  CHECK_CUDA(cudaGetLastError());

  // Copy the result to the host.
  CHECK_CUDA(cudaMemcpy(h_price, d_temp_storage, sizeof(double), cudaMemcpyDeviceToHost));
}

template< typename Payoff >
static double binomial_tree(int num_timesteps, const Payoff &payoff, double dt, double S0, double r, double sigma)
{
  double *tree = new double[num_timesteps+1];

  double u = std::exp( sigma * std::sqrt(dt));
  double d = std::exp(-sigma * std::sqrt(dt));
  double a = std::exp( r     * dt);
  
  double p = (a - d) / (u - d);
  
  double k = std::pow(d, num_timesteps);
  for( int t = 0 ; t <= num_timesteps ; ++t )
  {
    tree[t] = payoff(S0*k);
    k *= u*u;
  }

  for( int t = num_timesteps-1 ; t >= 0 ; --t )
  {
    k = std::pow(d, t);
    for( int i = 0 ; i <= t ; ++i )
    {
      double expected = std::exp(-r*dt) * (p*tree[i+1] + (1.0 - p)*tree[i]);
      double earlyex = payoff(S0*k);
      tree[i] = std::max(earlyex, expected);
      k *= u*u;
    }
  }

  double f = tree[0];
  delete[] tree;
  return f;
}

static double black_scholes_merton_put(double T, double K, double S0, double r, double sigma)
{
  double d1 = (std::log(S0 / K) + (r + 0.5*sigma*sigma)*T) / (sigma*std::sqrt(T));
  double d2 = d1 - sigma*std::sqrt(T);
  
  return K*std::exp(-r*T)*normcdf(-d2) - S0*normcdf(-d1);
}

static double black_scholes_merton_call(double T, double K, double S0, double r, double sigma)
{
  double d1 = (std::log(S0 / K) + (r + 0.5*sigma*sigma)*T) / (sigma*std::sqrt(T));
  double d2 = d1 - sigma*std::sqrt(T);
  
  return S0*normcdf(d1) - K*std::exp(-r*T)*normcdf(d2);
}

int main(int argc, char **argv)
{
  const int MAX_GRID_SIZE = 2048;
  
  // Simulation parameters.
  int num_timesteps = 100;
  int num_paths     = 32;
  int num_runs      = 1;

  // Option parameters.
  double T     = 1.00;
  double K     = 4.00;
  double S0    = 3.60;
  double r     = 0.06;
  double sigma = 0.20;

  // Bool do we price a put or a call.
  bool price_put = true;
  
  // Read command-line options.
  for( int i = 1 ; i < argc ; ++i )
  {
    if( !strcmp(argv[i], "-timesteps") )
      num_timesteps = strtol(argv[++i], NULL, 10);
    else if( !strcmp(argv[i], "-paths") )
      num_paths = strtol(argv[++i], NULL, 10);
    else if( !strcmp(argv[i], "-runs") )
      num_runs = strtol(argv[++i], NULL, 10);
    else if( !strcmp(argv[i], "-T") )
      T = strtod(argv[++i], NULL);
    else if( !strcmp(argv[i], "-S0") )
      S0 = strtod(argv[++i], NULL);
    else if( !strcmp(argv[i], "-K") )
      K = strtod(argv[++i], NULL);
    else if( !strcmp(argv[i], "-r") )
      r = strtod(argv[++i], NULL);
    else if( !strcmp(argv[i], "-sigma") )
      sigma = strtod(argv[++i], NULL);
    else if( !strcmp(argv[i], "-call") )
      price_put = false;
    else
    {
      fprintf(stderr, "Unknown option %s. Aborting!!!\n", argv[i]);
      exit(1);
    }
  }

  // Print the arguments.
  printf("==============\n");
  printf("Num Timesteps         : %d\n",  num_timesteps);
  printf("Num Paths             : %dK\n", num_paths);
  printf("Num Runs              : %d\n",  num_runs);
  printf("T                     : %lf\n", T);
  printf("S0                    : %lf\n", S0);
  printf("K                     : %lf\n", K);
  printf("r                     : %lf\n", r);
  printf("sigma                 : %lf\n", sigma);
  printf("Option Type           : American %s\n",  price_put ? "Put" : "Call");

  // We want x1024 paths.
  num_paths *= 1024;

  // A timestep.
  double dt = T / num_timesteps;

  // Generate random samples on a host
  std::default_random_engine rng;
  std::normal_distribution<double> norm_dist(0.0, 1.0);

  double *h_samples = (double*) malloc (num_timesteps*num_paths*sizeof(double));

  // Memory on the GPU to store normally distributed random numbers.
  double *d_samples = NULL;
  CHECK_CUDA(cudaMalloc((void**) &d_samples, num_timesteps*num_paths*sizeof(double)));

  // Memory on the GPU to store the asset price along the paths. The last column contains the discounted payoffs.
  double *d_paths = NULL;
  CHECK_CUDA(cudaMalloc((void**) &d_paths, num_timesteps*num_paths*sizeof(double)));

  // The discounted payoffs are the last column.
  double *d_cashflows = d_paths + (num_timesteps-1)*num_paths;

  // Storage to keep intermediate SVD matrices.
  double *d_svds = NULL;
  CHECK_CUDA(cudaMalloc((void**) &d_svds, 16*num_timesteps*sizeof(double)));

  // Memory on the GPU to flag timesteps where no path is in the money.
  int *d_all_out_of_the_money = NULL;
  CHECK_CUDA(cudaMalloc((void**) &d_all_out_of_the_money, num_timesteps*sizeof(int)));

  // Memory on the GPU to compute the reductions (beta and the option price).
  int max_temp_storage = 4*MAX_GRID_SIZE;
  double *d_temp_storage = NULL;
  CHECK_CUDA(cudaMalloc((void**) &d_temp_storage, max_temp_storage*sizeof(double)));

  // The price on the host.
  double h_price;

  // time the do_run function
  float total_elapsed_time = 0;

  for( int run = 0; run < num_runs; ++run )
  {
    for (int i = 0; i < num_timesteps*num_paths; ++i)
      h_samples[i] = norm_dist(rng);
      
    auto start = std::chrono::high_resolution_clock::now();
    if( price_put )
      do_run(h_samples,
             num_timesteps, 
             num_paths, 
             PayoffPut(K), 
             dt,
             S0,
             r,
             sigma,
             d_samples,
             d_paths,
             d_cashflows,
             d_svds,
             d_all_out_of_the_money,
             d_temp_storage,
             &h_price);
    else
      do_run(h_samples,
             num_timesteps, 
             num_paths, 
             PayoffCall(K), 
             dt,
             S0,
             r,
             sigma,
             d_samples,
             d_paths,
             d_cashflows,
             d_svds,
             d_all_out_of_the_money,
             d_temp_storage,
             &h_price);

    auto end = std::chrono::high_resolution_clock::now();
    const float elapsed_time =
       std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
    total_elapsed_time += elapsed_time;
  }

  printf("==============\n");
  printf("GPU Longstaff-Schwartz: %.8lf\n", h_price);
  
  double price = 0.0;

  if( price_put )
    price = binomial_tree(num_timesteps, PayoffPut(K), dt, S0, r, sigma);
  else
    price = binomial_tree(num_timesteps, PayoffCall(K), dt, S0, r, sigma);

  printf("Binonmial             : %.8lf\n", price);
  
  if( price_put )
    price = black_scholes_merton_put(T, K, S0, r, sigma);
  else
    price = black_scholes_merton_call(T, K, S0, r, sigma);

  printf("European Price        : %.8lf\n", price);

  printf("==============\n");

  printf("elapsed time for each run         : %.3fms\n", total_elapsed_time / num_runs);
  printf("==============\n");

  // Release memory
  free(h_samples);
  CHECK_CUDA(cudaFree(d_temp_storage));
  CHECK_CUDA(cudaFree(d_all_out_of_the_money));
  CHECK_CUDA(cudaFree(d_svds));
  CHECK_CUDA(cudaFree(d_paths));
  CHECK_CUDA(cudaFree(d_samples));

  return 0;
}
