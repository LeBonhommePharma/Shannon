// =============================================================================
// Shannon Metal Host — Objective-C++ Metal compute pipeline management
//
// Manages Metal device, command queue, pipeline states, and buffer allocation
// for GPU-accelerated entropy computation on Apple Silicon.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#ifdef SHANNON_HAS_METAL

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "shannon_metal.h"
#include <cmath>
#include <mutex>
#include <vector>
#include <numbers>

namespace shannon {
namespace metal {

// =============================================================================
// Metal context — persistent device, queue, and pipeline states
// =============================================================================

static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLLibrary> g_library = nil;

// Pipeline states
static id<MTLComputePipelineState> g_entropy_probs_pipeline = nil;
static id<MTLComputePipelineState> g_find_max_pipeline = nil;
static id<MTLComputePipelineState> g_entropy_logits_pipeline = nil;
static id<MTLComputePipelineState> g_weighted_entropy_pipeline = nil;
static id<MTLComputePipelineState> g_pairwise_dist_pipeline = nil;

// Persistent buffers
static id<MTLBuffer> g_data_buffer = nil;
static id<MTLBuffer> g_partial_buffer = nil;
static id<MTLBuffer> g_matrix_buffer = nil;  // 256x256 energy matrix
static size_t g_max_n = 0;
static bool g_initialized = false;
static bool g_matrix_loaded = false;
static std::mutex g_mutex;

static constexpr size_t BLOCK_SIZE = 256;
static constexpr size_t MAX_BLOCKS = 256;

// =============================================================================
// Helper: create compute pipeline from function name
// =============================================================================

static id<MTLComputePipelineState> create_pipeline(NSString* functionName) {
    id<MTLFunction> function = [g_library newFunctionWithName:functionName];
    if (!function) return nil;

    NSError* error = nil;
    id<MTLComputePipelineState> pipeline =
        [g_device newComputePipelineStateWithFunction:function error:&error];
    if (error) return nil;

    return pipeline;
}

// =============================================================================
// Helper: run reduction and read back partial sums
// =============================================================================

static double reduce_partial_sums(id<MTLBuffer> buffer, size_t count) {
    float* data = static_cast<float*>([buffer contents]);
    double sum = 0.0;
    for (size_t i = 0; i < count; ++i) {
        sum += static_cast<double>(data[i]);
    }
    return sum;
}

// =============================================================================
// Public API
// =============================================================================

bool shannon_metal_init(size_t max_vocab_size) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_initialized && max_vocab_size <= g_max_n) return true;

    @autoreleasepool {
        // Get default Metal device
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) return false;

        g_queue = [g_device newCommandQueue];
        if (!g_queue) return false;

        // Load shader library from default metallib or source
        NSError* error = nil;

        // Try loading compiled metallib first
        NSString* libPath = [[NSBundle mainBundle] pathForResource:@"shannon_metal"
                                                            ofType:@"metallib"];
        if (libPath) {
            g_library = [g_device newLibraryWithFile:libPath error:&error];
        }

        // Fall back to compiling from source at runtime
        if (!g_library) {
            NSString* sourcePath = [[NSBundle mainBundle] pathForResource:@"shannon_metal"
                                                                   ofType:@"metal"];
            if (sourcePath) {
                NSString* source = [NSString stringWithContentsOfFile:sourcePath
                                                             encoding:NSUTF8StringEncoding
                                                                error:&error];
                if (source) {
                    g_library = [g_device newLibraryWithSource:source options:nil error:&error];
                }
            }
        }

        if (!g_library) return false;

        // Create pipeline states
        g_entropy_probs_pipeline = create_pipeline(@"entropy_from_probs");
        g_find_max_pipeline = create_pipeline(@"find_max_logit");
        g_entropy_logits_pipeline = create_pipeline(@"entropy_from_logits");
        g_weighted_entropy_pipeline = create_pipeline(@"weighted_entropy");
        g_pairwise_dist_pipeline = create_pipeline(@"pairwise_distances");

        if (!g_entropy_probs_pipeline) return false;

        // Allocate persistent buffers
        g_max_n = max_vocab_size;
        g_data_buffer = [g_device newBufferWithLength:g_max_n * sizeof(float)
                                              options:MTLResourceStorageModeShared];
        g_partial_buffer = [g_device newBufferWithLength:MAX_BLOCKS * 2 * sizeof(float)
                                                 options:MTLResourceStorageModeShared];

        if (!g_data_buffer || !g_partial_buffer) return false;

        g_initialized = true;
        return true;
    }
}

double shannon_metal_entropy(const double* host_probs, size_t n) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || n > g_max_n || !g_entropy_probs_pipeline) return -1.0;

    @autoreleasepool {
        // Convert double to float and copy to buffer
        float* buf = static_cast<float*>([g_data_buffer contents]);
        for (size_t i = 0; i < n; ++i) {
            buf[i] = static_cast<float>(host_probs[i]);
        }

        uint32_t n32 = static_cast<uint32_t>(n);
        size_t num_blocks = std::min((n + BLOCK_SIZE - 1) / BLOCK_SIZE, MAX_BLOCKS);

        id<MTLCommandBuffer> cmdBuffer = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cmdBuffer computeCommandEncoder];

        [encoder setComputePipelineState:g_entropy_probs_pipeline];
        [encoder setBuffer:g_data_buffer offset:0 atIndex:0];
        [encoder setBuffer:g_partial_buffer offset:0 atIndex:1];
        [encoder setBytes:&n32 length:sizeof(n32) atIndex:2];
        [encoder setThreadgroupMemoryLength:BLOCK_SIZE * sizeof(float) atIndex:0];

        MTLSize gridSize = MTLSizeMake(num_blocks * BLOCK_SIZE, 1, 1);
        MTLSize tgSize = MTLSizeMake(BLOCK_SIZE, 1, 1);
        [encoder dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
        [encoder endEncoding];

        [cmdBuffer commit];
        [cmdBuffer waitUntilCompleted];

        return reduce_partial_sums(g_partial_buffer, num_blocks);
    }
}

double shannon_metal_entropy_from_logits(const double* host_logits, size_t n) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || n > g_max_n || !g_find_max_pipeline || !g_entropy_logits_pipeline)
        return -1.0;

    @autoreleasepool {
        // Convert double to float
        float* buf = static_cast<float*>([g_data_buffer contents]);
        for (size_t i = 0; i < n; ++i) {
            buf[i] = static_cast<float>(host_logits[i]);
        }

        uint32_t n32 = static_cast<uint32_t>(n);
        size_t num_blocks = std::min((n + BLOCK_SIZE - 1) / BLOCK_SIZE, MAX_BLOCKS);

        // Pass 1: find max
        {
            id<MTLCommandBuffer> cmdBuffer = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [cmdBuffer computeCommandEncoder];

            [encoder setComputePipelineState:g_find_max_pipeline];
            [encoder setBuffer:g_data_buffer offset:0 atIndex:0];
            [encoder setBuffer:g_partial_buffer offset:0 atIndex:1];
            [encoder setBytes:&n32 length:sizeof(n32) atIndex:2];
            [encoder setThreadgroupMemoryLength:BLOCK_SIZE * sizeof(float) atIndex:0];

            MTLSize gridSize = MTLSizeMake(num_blocks * BLOCK_SIZE, 1, 1);
            MTLSize tgSize = MTLSizeMake(BLOCK_SIZE, 1, 1);
            [encoder dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
            [encoder endEncoding];
            [cmdBuffer commit];
            [cmdBuffer waitUntilCompleted];
        }

        // Find global max from partial results
        float* partial = static_cast<float*>([g_partial_buffer contents]);
        float max_logit = partial[0];
        for (size_t i = 1; i < num_blocks; ++i) {
            if (partial[i] > max_logit) max_logit = partial[i];
        }

        // Pass 2: fused exp sum
        id<MTLBuffer> sum_exp_buffer = [g_device newBufferWithLength:MAX_BLOCKS * sizeof(float)
                                                              options:MTLResourceStorageModeShared];
        id<MTLBuffer> sum_x_exp_buffer = [g_device newBufferWithLength:MAX_BLOCKS * sizeof(float)
                                                                options:MTLResourceStorageModeShared];
        {
            id<MTLCommandBuffer> cmdBuffer = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [cmdBuffer computeCommandEncoder];

            [encoder setComputePipelineState:g_entropy_logits_pipeline];
            [encoder setBuffer:g_data_buffer offset:0 atIndex:0];
            [encoder setBuffer:sum_exp_buffer offset:0 atIndex:1];
            [encoder setBuffer:sum_x_exp_buffer offset:0 atIndex:2];
            [encoder setBytes:&max_logit length:sizeof(max_logit) atIndex:3];
            [encoder setBytes:&n32 length:sizeof(n32) atIndex:4];
            [encoder setThreadgroupMemoryLength:BLOCK_SIZE * sizeof(float) atIndex:0];
            [encoder setThreadgroupMemoryLength:BLOCK_SIZE * sizeof(float) atIndex:1];

            MTLSize gridSize = MTLSizeMake(num_blocks * BLOCK_SIZE, 1, 1);
            MTLSize tgSize = MTLSizeMake(BLOCK_SIZE, 1, 1);
            [encoder dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
            [encoder endEncoding];
            [cmdBuffer commit];
            [cmdBuffer waitUntilCompleted];
        }

        double sum_exp = reduce_partial_sums(sum_exp_buffer, num_blocks);
        double sum_x_exp = reduce_partial_sums(sum_x_exp_buffer, num_blocks);

        double log_Z = static_cast<double>(max_logit) + std::log(sum_exp);
        double mean_logit = sum_x_exp / sum_exp;
        double H = std::numbers::log2e * (log_Z - mean_logit);
        return std::max(H, 0.0);
    }
}

double shannon_metal_weighted_entropy(
    const double* host_probs, size_t n,
    const float* matrix_data,
    const unsigned char* token_ids, size_t context_len
) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || n > g_max_n || !g_weighted_entropy_pipeline) return -1.0;

    @autoreleasepool {
        // Load energy matrix (one-time)
        if (!g_matrix_loaded && matrix_data) {
            g_matrix_buffer = [g_device newBufferWithBytes:matrix_data
                                                    length:256 * 256 * sizeof(float)
                                                   options:MTLResourceStorageModeShared];
            g_matrix_loaded = true;
        }
        if (!g_matrix_buffer) return -1.0;

        // Convert probs to float
        float* buf = static_cast<float*>([g_data_buffer contents]);
        for (size_t i = 0; i < n; ++i) {
            buf[i] = static_cast<float>(host_probs[i]);
        }

        // Token IDs buffer
        id<MTLBuffer> token_buffer = [g_device newBufferWithBytes:token_ids
                                                            length:context_len
                                                           options:MTLResourceStorageModeShared];

        uint32_t n32 = static_cast<uint32_t>(n);
        uint32_t ctx32 = static_cast<uint32_t>(context_len);
        float inv_ctx = 1.0f / static_cast<float>(context_len);
        size_t num_blocks = std::min((n + BLOCK_SIZE - 1) / BLOCK_SIZE, MAX_BLOCKS);

        id<MTLCommandBuffer> cmdBuffer = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cmdBuffer computeCommandEncoder];

        [encoder setComputePipelineState:g_weighted_entropy_pipeline];
        [encoder setBuffer:g_data_buffer offset:0 atIndex:0];
        [encoder setBuffer:g_matrix_buffer offset:0 atIndex:1];
        [encoder setBuffer:token_buffer offset:0 atIndex:2];
        [encoder setBuffer:g_partial_buffer offset:0 atIndex:3];
        [encoder setBytes:&n32 length:sizeof(n32) atIndex:4];
        [encoder setBytes:&ctx32 length:sizeof(ctx32) atIndex:5];
        [encoder setBytes:&inv_ctx length:sizeof(inv_ctx) atIndex:6];
        [encoder setThreadgroupMemoryLength:BLOCK_SIZE * sizeof(float) atIndex:0];

        MTLSize gridSize = MTLSizeMake(num_blocks * BLOCK_SIZE, 1, 1);
        MTLSize tgSize = MTLSizeMake(BLOCK_SIZE, 1, 1);
        [encoder dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
        [encoder endEncoding];
        [cmdBuffer commit];
        [cmdBuffer waitUntilCompleted];

        return reduce_partial_sums(g_partial_buffer, num_blocks);
    }
}

void shannon_metal_pairwise_distances(
    const float* host_data, size_t n, size_t d,
    float* dist_out
) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || !g_pairwise_dist_pipeline) return;

    @autoreleasepool {
        id<MTLBuffer> data_buf = [g_device newBufferWithBytes:host_data
                                                        length:n * d * sizeof(float)
                                                       options:MTLResourceStorageModeShared];
        id<MTLBuffer> dist_buf = [g_device newBufferWithLength:n * n * sizeof(float)
                                                        options:MTLResourceStorageModeShared];

        uint32_t n32 = static_cast<uint32_t>(n);
        uint32_t d32 = static_cast<uint32_t>(d);

        id<MTLCommandBuffer> cmdBuffer = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cmdBuffer computeCommandEncoder];

        [encoder setComputePipelineState:g_pairwise_dist_pipeline];
        [encoder setBuffer:data_buf offset:0 atIndex:0];
        [encoder setBuffer:dist_buf offset:0 atIndex:1];
        [encoder setBytes:&n32 length:sizeof(n32) atIndex:2];
        [encoder setBytes:&d32 length:sizeof(d32) atIndex:3];

        MTLSize gridSize = MTLSizeMake(n, n, 1);
        MTLSize tgSize = MTLSizeMake(std::min(n, (size_t)16), std::min(n, (size_t)16), 1);
        [encoder dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
        [encoder endEncoding];
        [cmdBuffer commit];
        [cmdBuffer waitUntilCompleted];

        // Copy results
        memcpy(dist_out, [dist_buf contents], n * n * sizeof(float));
    }
}

void shannon_metal_shutdown() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_entropy_probs_pipeline = nil;
    g_find_max_pipeline = nil;
    g_entropy_logits_pipeline = nil;
    g_weighted_entropy_pipeline = nil;
    g_pairwise_dist_pipeline = nil;
    g_data_buffer = nil;
    g_partial_buffer = nil;
    g_matrix_buffer = nil;
    g_library = nil;
    g_queue = nil;
    g_device = nil;
    g_initialized = false;
    g_matrix_loaded = false;
    g_max_n = 0;
}

bool shannon_metal_available() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device != nil;
    }
}

}  // namespace metal
}  // namespace shannon

#endif  // SHANNON_HAS_METAL
