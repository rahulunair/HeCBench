#include "util.h"

//Round a / b to nearest higher integer value
__host__ int iDivUp(int a, int b) { return (a % b != 0) ? (a / b + 1) : (a / b); }

//Round a / b to nearest lower integer value
__host__ int iDivDown(int a, int b) { return a / b; }

//Align a to nearest higher multiple of b
__host__ int iAlignUp(int a, int b) { return (a % b != 0) ?  (a - a % b + b) : a; }

//Align a to nearest lower multiple of b
__host__ int iAlignDown(int a, int b)  {return a - a % b; }

//Round a / b to nearest higher integer value
__host__ int iDivUpF(int a, float b) { return (a % int(b) != 0) ? int(a / b + 1) : int(a / b);}

__host__ int iClosestPowerOfTwo(int x) { x--; x |= x >> 1; x |= x >> 2; x |= x >> 4; x |= x >> 8; x |= x >> 16; x++; return x; }

__host__ void Uchar4ToFloat4(uchar4 *inputImage, float4 *outputImage, int width, int height)
{
  dim3 threads_in_block(16,16);
  dim3 blocks(iDivUp(width,16), iDivUp(height,16));
  uchar4tofloat4<<<blocks, threads_in_block>>>(inputImage, outputImage, width, height);
}

__host__ void Float4ToUchar4(float4 *inputImage, uchar4 *outputImage, int width, int height)
{
  dim3 threads_in_block(16,16);
  dim3 blocks(iDivUp(width,16), iDivUp(height,16));
  float4toUchar4<<<blocks, threads_in_block>>>(inputImage, outputImage, width, height);
}

__global__ void float4toUchar4(
  const float4 * __restrict__ inputImage,
        uchar4 * __restrict__ outputImage,
  int width, int height)
{
  int offsetBlock = blockIdx.x * blockDim.x + blockIdx.y * blockDim.y * width;
  int offset = offsetBlock + threadIdx.x + threadIdx.y * width;

  float4 pixelf = inputImage[offset];
  uchar4 pixel;
  pixel.x = (unsigned char) pixelf.x; pixel.y = (unsigned char) pixelf.y;
  pixel.z = (unsigned char) pixelf.z; pixel.w = (unsigned char) pixelf.w;

  outputImage[offset] = pixel;
}

__global__ void uchar4tofloat4(
  const uchar4 * __restrict__ inputImage,
        float4 * __restrict__ outputImage,
  int width, int height)
{
  int offsetX = blockIdx.x * blockDim.x + threadIdx.x;
  int offsetY = blockIdx.y * blockDim.y + threadIdx.y;

  if (offsetX < width && offsetY < height)
  {
    int offsetBlock = blockIdx.x * blockDim.x + blockIdx.y * blockDim.y * width;
    int offset = offsetBlock + threadIdx.x + threadIdx.y * width;

    uchar4 pixel = inputImage[offset];
    float4 pixelf;
    pixelf.x = pixel.x; pixelf.y = pixel.y;
    pixelf.z = pixel.z; pixelf.w = pixel.w;

    outputImage[offset] = pixelf;
  }
}