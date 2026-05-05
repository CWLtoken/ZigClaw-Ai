// src/image_feature.h
// ZigClaw V2.4 | B阶段 | 图像特征提取接口（真实 stb_image 预留）
#ifndef IMAGE_FEATURE_H
#define IMAGE_FEATURE_H

#include <stdint.h>

// 提取图像特征，输出 64 维向量（范围 [-1, 1]）
// 返回 0 成功，非 0 失败
// 真实实现用 stb_image 加载图像，提取颜色/纹理/形状特征
int extract_image_features(const char* image_path, float features[64]);

#endif
