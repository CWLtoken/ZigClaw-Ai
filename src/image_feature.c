// src/image_feature.c
// ZigClaw V2.4 | B阶段 | 真实图像特征提取（stb_image 实现）
#define STB_IMAGE_IMPLEMENTATION  // 必须定义在 #include 之前
#include "image_feature.h"
#include "stb_image.h"
#include <string.h>
#include <math.h>

// 提取图像特征，输出 64 维向量（范围 [-1, 1]）
// 真实实现：用 stb_image 加载图像，提取颜色直方图 + 纹理特征
int extract_image_features(const char* image_path, float features[64]) {
    int width, height, channels;
    
    // 1. 用 stb_image 加载图像
    unsigned char* img_data = stbi_load(image_path, &width, &height, &channels, 3); // 强制转 3 通道（RGB）
    if (img_data == NULL) {
        return -1; // 加载失败
    }

    // 2. 初始化特征向量为 0
    memset(features, 0, 64 * sizeof(float));

    // 3. 提取颜色直方图（48 维：每个通道 16 个 bin）
    // R: 0-15, G: 16-31, B: 32-47
    int hist_r[16] = {0};
    int hist_g[16] = {0};
    int hist_b[16] = {0};
    
    int total_pixels = width * height;
    for (int i = 0; i < total_pixels; i++) {
        unsigned char r = img_data[i * 3 + 0];
        unsigned char g = img_data[i * 3 + 1];
        unsigned char b = img_data[i * 3 + 2];
        
        hist_r[r >> 4]++; // 高 4 位作为 bin（0-15）
        hist_g[g >> 4]++;
        hist_b[b >> 4]++;
    }

    // 归一化直方图到 [-1, 1]： (hist - avg) / max，然后缩放到 [-1,1]
    float inv_total = 1.0f / (float)total_pixels;
    for (int i = 0; i < 16; i++) {
        features[i]     = (hist_r[i] * inv_total * 2.0f) - 1.0f; // R: 0-15
        features[i+16]  = (hist_g[i] * inv_total * 2.0f) - 1.0f; // G: 16-31
        features[i+32]  = (hist_b[i] * inv_total * 2.0f) - 1.0f; // B: 32-47
    }

    // 4. 提取简单纹理特征（16 维：亮度梯度统计）
    // 计算亮度（Y = 0.299R + 0.587G + 0.114B）
    float grad_x_sum = 0.0f, grad_y_sum = 0.0f;
    int grad_count = 0;
    for (int y = 0; y < height - 1; y++) {
        for (int x = 0; x < width - 1; x++) {
            int idx = (y * width + x) * 3;
            float r = img_data[idx], g = img_data[idx+1], b = img_data[idx+2];
            float Y = 0.299f * r + 0.587f * g + 0.114f * b;
            
            // 计算 x 方向梯度
            int idx_x = (y * width + (x+1)) * 3;
            float r_x = img_data[idx_x], g_x = img_data[idx_x+1], b_x = img_data[idx_x+2];
            float Y_x = 0.299f * r_x + 0.587f * g_x + 0.114f * b_x;
            float grad_x = Y_x - Y;
            
            // 计算 y 方向梯度
            int idx_y = ((y+1) * width + x) * 3;
            float r_y = img_data[idx_y], g_y = img_data[idx_y+1], b_y = img_data[idx_y+2];
            float Y_y = 0.299f * r_y + 0.587f * g_y + 0.114f * b_y;
            float grad_y = Y_y - Y;
            
            grad_x_sum += fabs(grad_x);
            grad_y_sum += fabs(grad_y);
            grad_count++;
        }
    }

    // 梯度统计特征（48-63 维）
    if (grad_count > 0) {
        features[48] = (grad_x_sum / grad_count) / 128.0f - 1.0f; // 平均 x 梯度
        features[49] = (grad_y_sum / grad_count) / 128.0f - 1.0f; // 平均 y 梯度
        // 剩余 14 维填充为 0（可扩展更多纹理特征）
        for (int i = 50; i < 64; i++) {
            features[i] = 0.0f;
        }
    }

    // 5. 释放图像内存
    stbi_image_free(img_data);
    
    return 0; // 成功
}
