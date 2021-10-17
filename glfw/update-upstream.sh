#!/usr/bin/env bash
set -ex

# GLFW
rm -rf upstream/
mkdir upstream/
cd upstream/
git clone https://github.com/glfw/glfw
cd glfw/
git checkout 3.3.4

# Remove non-C files
rm -rf .appveyor.yml .git .gitattributes .gitignore .mailmap .travis.yml
rm cmake_uninstall.cmake.in README.md
rm -r CMake* deps/ examples/ tests/ docs/
rm src/CMakeLists.txt src/*.in

# Vulkan headers
cd ..
git clone https://github.com/KhronosGroup/Vulkan-Headers vulkan_headers/
cd vulkan_headers
rm -rf .git registry/ *.gn *.txt *.md cmake/ 
rm -rf include/vk_video
