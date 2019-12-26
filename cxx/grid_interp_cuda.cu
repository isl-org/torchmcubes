#include <torch/extension.h>

#include <cuda_runtime.h>

#include "macros.h"

__global__ void grid_interp_cuda_kernel(
    const torch::PackedTensorAccessor<float, 4, torch::RestrictPtrTraits, size_t> vol,
    const torch::PackedTensorAccessor<float, 2, torch::RestrictPtrTraits, size_t> points,
    torch::PackedTensorAccessor<float, 2, torch::RestrictPtrTraits, size_t> output,
    int channels, int3 nGrids, size_t size) {
    
    const int tx = blockIdx.x * blockDim.x + threadIdx.x;
    const int ty = blockIdx.y * blockDim.y + threadIdx.y;
    const int tz = blockIdx.z * blockDim.z + threadIdx.z;    
    const int index = (tz * blockDim.y * gridDim.y + ty) * blockDim.x * gridDim.x + tx;
    if (index >= size) {
        return;
    }

    const float x = points[index][0];
    const float y = points[index][1];
    const float z = points[index][2];

    const int ix = (int)x;
    const int iy = (int)y;
    const int iz = (int)z;
    const float fx = x - ix;
    const float fy = y - iy;
    const float fz = z - iz;

    for (int c = 0; c < channels; c++) {
        const int x0 = max(0, min(ix, nGrids.x - 1));
        const int x1 = max(0, min(ix + 1, nGrids.x - 1));
        const int y0 = max(0, min(iy, nGrids.y - 1));
        const int y1 = max(0, min(iy + 1, nGrids.y - 1));
        const int z0 = max(0, min(iz, nGrids.z - 1));
        const int z1 = max(0, min(iz + 1, nGrids.z - 1));

        const float v00 = (1.0 - fx) * vol[c][z0][y0][x0] + fx * vol[c][z0][y0][x1];
        const float v01 = (1.0 - fx) * vol[c][z0][y1][x0] + fx * vol[c][z0][y1][x1];
        const float v10 = (1.0 - fx) * vol[c][z1][y0][x0] + fx * vol[c][z1][y0][x1];
        const float v11 = (1.0 - fx) * vol[c][z1][y1][x0] + fx * vol[c][z1][y1][x1];
        
        const float v0 = (1.0 - fy) * v00 + fy * v01;
        const float v1 = (1.0 - fy) * v10 + fy * v11;

        output[index][c] = (1.0 - fz) * v0 + fz * v1;
    }         
}

torch::Tensor grid_interp_cuda(torch::Tensor vol, torch::Tensor points) {
    CHECK_CUDA(vol);
    CHECK_CONTIGUOUS(vol);
    CHECK_N_DIM(vol, 4);

    CHECK_CUDA(points);
    CHECK_CONTIGUOUS(points);
    CHECK_N_DIM(points, 2);

    const int Nx = vol.size(3);
    const int Ny = vol.size(2);
    const int Nz = vol.size(1);
    const int C = vol.size(0);
    const int Np = points.size(0);

    torch::Tensor output = torch::zeros({Np, C},
        torch::TensorOptions().dtype(torch::kFloat32).device(vol.device()));

    auto vol_ascr = vol.packed_accessor<float, 4, torch::RestrictPtrTraits, size_t>();
    auto pts_ascr = points.packed_accessor<float, 2, torch::RestrictPtrTraits, size_t>();
    auto out_ascr = output.packed_accessor<float, 2, torch::RestrictPtrTraits, size_t>();    

    const uint32_t MAX_THREADS_AXIS = 128;
    const uint32_t MAX_THREADS_AXIS2 = MAX_THREADS_AXIS * MAX_THREADS_AXIS;
    const uint32_t blockx = MAX_THREADS_AXIS;
    const uint32_t blocky = MAX_THREADS_AXIS;
    const uint32_t blockz = (Np + MAX_THREADS_AXIS2 - 1) / MAX_THREADS_AXIS2;

    const uint32_t BLOCK_SIZE = 8;
    const uint32_t gridx = (blockx + BLOCK_SIZE - 1) / BLOCK_SIZE;
    const uint32_t gridy = (blocky + BLOCK_SIZE - 1) / BLOCK_SIZE;
    const uint32_t gridz = (blockz + BLOCK_SIZE - 1) / BLOCK_SIZE;
    const int3 nGrids = make_int3(Nx, Ny, Nz);
    const dim3 blocks = { gridx, gridy, gridz };
    const dim3 threads = { BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE };
    grid_interp_cuda_kernel<<<blocks, threads>>>(vol_ascr, pts_ascr, out_ascr, C, nGrids, Np);

    return output;
}
