/*
 * Copyright 2016
 *
 * Backprojection.cu
 *
 *  Created on: 26.05.2016
 *      Author: Tobias Frust (t.frust@hzdr.de)
 */

#include <risa/Backprojection/Backprojection.h>
#include <risa/ConfigReader/ConfigReader.h>

#include <ddrf/MemoryPool.h>
#include <ddrf/cuda/Coordinates.h>

#include <boost/log/trivial.hpp>

#include <nvToolsExt.h>

#include <exception>
#include <pthread.h>

namespace risa {
namespace cuda {

template<typename T>
__host__  __device__
 inline T lerp(T v0, T v1, T t) {
   return fma(t, v1, fma(-t, v0, v0));
}

__global__ void backProjectLinear(const float* const __restrict__ sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors);

__global__ void backProjectNearest(const float* const __restrict__ sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors);

__global__ void backProjectNearSymm(const float*  __restrict__ const sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors);

__global__ void backProjectNearest3D(const float* const __restrict__ sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors);

__constant__ float sinLookup[2048];
__constant__ float cosLookup[2048];
__constant__ float normalizationFactor[1];
__constant__ float scale[1];
__constant__ float imageCenter[1];

Backprojection::Backprojection(const std::string& configFile) {

   if (readConfig(configFile)) {
      throw std::runtime_error(
            "recoLib::cuda::Backprojection: Configuration file could not be loaded successfully. Please check!");
   }

   CHECK(cudaGetDeviceCount(&numberOfDevices_));

   numberOfStreams_ = 1;

   lastStreams_.resize(numberOfStreams_);

   //allocate memory in memory pool for each device
   for (auto i = 0; i < numberOfDevices_; i++) {
      CHECK(cudaSetDevice(i));
      for(auto sInd = 0; sInd < numberOfStreams_; sInd++){
         memoryPoolIdxs_.push_back(
            ddrf::MemoryPool<deviceManagerType>::instance()->registerStage(
                  memPoolSize_, numberOfPixels_ * numberOfPixels_));
         }
   }

   for (auto i = 0; i < numberOfDevices_; i++) {
      CHECK(cudaSetDevice(i));
      for(auto sInd = 0; sInd < numberOfStreams_; sInd++){
         //custom streams are necessary, because profiling with nvprof seems to be
         //not possible with -default-stream per-thread option
         cudaStream_t stream;
         CHECK(cudaStreamCreate(&stream));
         streams_[sInd+numberOfStreams_*i] = stream;
      }
   }

   //initialize worker thread
   for (auto i = 0; i < numberOfDevices_; i++) {
      for(auto sInd = 0; sInd < numberOfStreams_; sInd++){
         processorThreads_[sInd+numberOfStreams_*i] =
            std::thread { &Backprojection::processor, this, i, sInd };
      }
   }
   BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Backprojection: Running " << numberOfDevices_ << " Threads.";
}

Backprojection::~Backprojection() {
   for (auto idx : memoryPoolIdxs_) {
      ddrf::MemoryPool<deviceManagerType>::instance()->freeMemory(idx);
   }
   for (auto& ele : streams_) {
      //CHECK(cudaSetDevice(ele.first/numberOfStreams_));
      CHECK(cudaStreamDestroy(ele.second));
   }
   BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::Backprojection: Destroyed.";
}

/**
 *  Main method of each stage. Is called, when new input data arrives.
 *  Pushes input data into local queue; for processing in processor method.
 *
 */
auto Backprojection::process(input_type&& sinogram) -> void {
   if (sinogram.valid()) {
      BOOST_LOG_TRIVIAL(debug)<< "BP: Image arrived with Index: " << sinogram.index() << "to device " << sinogram.device();
      sinograms_[sinogram.device()*numberOfStreams_+lastStreams_[sinogram.device()]].push(std::move(sinogram));
      lastStreams_[sinogram.device()] = (lastStreams_[sinogram.device()]+1) % numberOfStreams_;
   } else {
      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Backprojection: Received sentinel, finishing.";

      //send sentinal to processor thread and wait 'til it's finished
      for(auto i = 0; i < numberOfDevices_*numberOfStreams_; i++) {
         sinograms_[i].push(input_type());
      }
      for(auto i = 0; i < numberOfDevices_*numberOfStreams_; i++) {
         processorThreads_[i].join();
      }

      results_.push(output_type());
      BOOST_LOG_TRIVIAL(info) << "recoLib::cuda::Backprojection: Finished.";
   }
}

auto Backprojection::wait() -> output_type {
   return results_.take();
}

/**
 * Takes sinogram from the input queue and performs the forward projection
 * using a sparse-matrix-vector multiplication from the cuSparse-Library.
 * Uses the MemoryPool, thus, now expensive memory allocation needs to be
 * performed. No blocking of device.
 * Finally, the reconstructed image is pushed back into the output queue
 * for further processing.
 *
 */
auto Backprojection::processor(const int deviceID, const int streamID) -> void {
   //nvtxNameOsThreadA(pthread_self(), "Reco");
   CHECK(cudaSetDevice(deviceID));

   //init lookup tables for sin and cos
   std::vector<float> sinLookup_h(numberOfProjections_), cosLookup_h(
         numberOfProjections_);
   auto sinLookup_d = ddrf::cuda::make_device_ptr<float,
         ddrf::cuda::async_copy_policy>(numberOfProjections_);
   auto cosLookup_d = ddrf::cuda::make_device_ptr<float,
         ddrf::cuda::async_copy_policy>(numberOfProjections_);
   for (auto i = 0; i < numberOfProjections_; i++) {
      float theta = i * M_PI
            / (float) numberOfProjections_+ rotationOffset_ / 180.0 * M_PI;
      while (theta < 0.0) {
         theta += 2.0 * M_PI;
      }
      sincosf(theta, &sinLookup_h[i], &cosLookup_h[i]);
   }
   CHECK(
         cudaMemcpyToSymbol(sinLookup, sinLookup_h.data(),
               sizeof(float) * numberOfProjections_));
   CHECK(
         cudaMemcpyToSymbol(cosLookup, cosLookup_h.data(),
               sizeof(float) * numberOfProjections_));
   //constants for kernel
   const float scale_h = numberOfDetectors_ / (float) numberOfPixels_;
   const float normalizationFactor_h = M_PI / numberOfProjections_ / scale_h;
   const float imageCenter_h = (numberOfPixels_ - 1.0) * 0.5;
   CHECK(cudaMemcpyToSymbol(normalizationFactor, &normalizationFactor_h, sizeof(float)));
   CHECK(cudaMemcpyToSymbol(scale, &scale_h, sizeof(float)));
   CHECK(cudaMemcpyToSymbol(imageCenter, &imageCenter_h, sizeof(float)));
   dim3 blocks(blockSize2D_, blockSize2D_);
   dim3 grids(std::ceil(numberOfPixels_ / (float) blockSize2D_),
         std::ceil(numberOfPixels_ / (float) blockSize2D_));
//   dim3 blocks(8, 8, 8);
//   dim3 grids(std::ceil(numberOfPixels_ / 8.0),
//         std::ceil(numberOfPixels_ / 8.0),
//         std::ceil(numberOfProjections_ / 8.0));

   //CHECK(cudaFuncSetCacheConfig(backProjectLinear, cudaFuncCachePreferL1));
   BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::BP: Running Thread for Device " << deviceID;
   while (true) {
      //execution is blocked until next element arrives in queue
      auto sinogram = sinograms_[deviceID*numberOfStreams_+streamID].take();
      //if sentinel, finish thread execution
      if (!sinogram.valid())
         break;

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Backprojection: Backprojecting sinogram with Index " << sinogram.index();

      //allocate device memory for reconstructed picture
      auto recoImage =
            ddrf::MemoryPool<deviceManagerType>::instance()->requestMemory(
                  memoryPoolIdxs_[deviceID*numberOfStreams_+streamID]);

      if(interpolationType_ == detail::InterpolationType::linear)
         backProjectLinear<<<grids, blocks, 0, streams_[deviceID*numberOfStreams_ + streamID]>>>(
               sinogram.container().get(), recoImage.container().get(),
               numberOfPixels_, numberOfProjections_, numberOfDetectors_);
      else if(interpolationType_ == detail::InterpolationType::neareastNeighbor)
         backProjectNearest<<<grids, blocks, 0, streams_[deviceID*numberOfStreams_ + streamID]>>>(
               sinogram.container().get(), recoImage.container().get(),
               numberOfPixels_, numberOfProjections_, numberOfDetectors_);
      CHECK(cudaPeekAtLastError());

      recoImage.setIdx(sinogram.index());
      recoImage.setDevice(deviceID);
      recoImage.setPlane(sinogram.plane());

      //wait until work on device is finished
      CHECK(cudaStreamSynchronize(streams_[deviceID*numberOfStreams_ + streamID]));
      results_.push(std::move(recoImage));

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::Backprojection: Reconstructing sinogram with Index " << sinogram.index() << " finished.";
   }
}

auto Backprojection::readConfig(const std::string& configFile) -> bool {
   recoLib::ConfigReader configReader = recoLib::ConfigReader(
         configFile.data());
   std::string interpolationStr;
   if (configReader.lookupValue("numberOfParallelProjections", numberOfProjections_)
         && configReader.lookupValue("numberOfParallelDetectors", numberOfDetectors_)
         && configReader.lookupValue("numberOfPixels", numberOfPixels_)
         && configReader.lookupValue("rotationOffset", rotationOffset_)
         && configReader.lookupValue("blockSize2D_backProjection", blockSize2D_)
         && configReader.lookupValue("memPoolSize_backProjection", memPoolSize_)
         && configReader.lookupValue("interpolationType", interpolationStr)){
      if(interpolationStr == "nearestNeighbour")
         interpolationType_ = detail::InterpolationType::neareastNeighbor;
      else if(interpolationStr == "linear")
         interpolationType_ = detail::InterpolationType::linear;
      else{
         BOOST_LOG_TRIVIAL(error) << "recoLib::cuda::Backprojection: Requested interpolation mode not supported. Using linear-interpolation.";
         interpolationType_ = detail::InterpolationType::linear;
      }

      return EXIT_SUCCESS;
   }

   return EXIT_FAILURE;
}

__global__ void backProjectLinear(const float* const __restrict__ sinogram,
         float* __restrict__ image,
         const int numberOfPixels,
         const int numberOfProjections,
         const int numberOfDetectors){

   const auto x = ddrf::cuda::getX();
   const auto y = ddrf::cuda::getY();

   float sum = 0.0;

   if(x >= numberOfPixels || y >= numberOfPixels)
      return;

   const int centerIndex = numberOfDetectors * 0.5;

   const float xp = (x - imageCenter[0]) * scale[0];
   const float yp = (y - imageCenter[0]) * scale[0];

#pragma unroll 4
   for(auto projectionInd = 0; projectionInd < numberOfProjections; projectionInd++){
      const float t = xp * cosLookup[projectionInd] + yp * sinLookup[projectionInd];
      const int a = floor(t);
      const int aCenter = a + centerIndex;
      if(aCenter >= 0 && aCenter < numberOfDetectors){
         sum = sum + ((float)(a + 1) - t) * sinogram[projectionInd * numberOfDetectors + aCenter];
      }
      if((aCenter + 1) >= 0 && (aCenter + 1) < numberOfDetectors){
         sum = sum + (t - (float)a) * sinogram[projectionInd * numberOfDetectors + aCenter + 1];
      }

   }
   image[x + y * numberOfPixels] = sum * normalizationFactor[0];
}

__global__ void backProjectNearSymm(const float*  __restrict__ const sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors) {

   const auto x = ddrf::cuda::getX();
   const auto y = ddrf::cuda::getY();

   if (x >= numberOfPixels || y >= numberOfPixels)
      return;

   float sum = 0.0;

   float *p_cosLookup = cosLookup;
   float *p_sinLookup = sinLookup;

   const float scale = numberOfPixels / (float) numberOfDetectors;
   const int centerIndex = numberOfDetectors * 0.5;

   const float xp = (x - (numberOfPixels - 1.0) * 0.5) / scale;
   const float yp = (y - (numberOfPixels - 1.0) * 0.5) / scale;

#pragma unroll 4
   for (auto projectionInd = 0; projectionInd < numberOfProjections/2; projectionInd++) {
      const float cosVal = *p_cosLookup;
      const float sinVal = *p_sinLookup;
      //const int t = round(xp * cosLookup[projectionInd] + yp * sinLookup[projectionInd]) + centerIndex;
      const int t1 = round(xp * cosVal + yp * sinVal) + centerIndex;
      const int t2 = round(yp * cosVal - xp * sinVal) + centerIndex;
      ++p_cosLookup; ++p_sinLookup;
      if (t1 >= 0 && t1 < numberOfDetectors)
         sum += sinogram[projectionInd * numberOfDetectors + t1];
      if (t2 >= 0 && t2 < numberOfDetectors)
         sum += sinogram[(projectionInd+numberOfProjections/2) * numberOfDetectors + t2];
   }
   image[x + y * numberOfPixels] = sum * normalizationFactor[0];
}


__global__ void backProjectNearest(const float* const __restrict__ sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors) {

   const auto x = ddrf::cuda::getX();
   const auto y = ddrf::cuda::getY();

   if (x >= numberOfPixels || y >= numberOfPixels)
      return;

   float sum = 0.0;

   float *p_cosLookup = cosLookup;
   float *p_sinLookup = sinLookup;

   const float scale = numberOfPixels / (float) numberOfDetectors;
   const int centerIndex = numberOfDetectors * 0.5;

   const float xp = (x - (numberOfPixels - 1.0) * 0.5) / scale;
   const float yp = (y - (numberOfPixels - 1.0) * 0.5) / scale;

#pragma unroll 4
   for (auto projectionInd = 0; projectionInd < numberOfProjections;
         projectionInd++) {
      //const int t = round(xp * cosLookup[projectionInd] + yp * sinLookup[projectionInd]) + centerIndex;
      const int t = round(xp * *p_cosLookup + yp * *p_sinLookup) + centerIndex;
      ++p_cosLookup; ++p_sinLookup;
      if (t >= 0 && t < numberOfDetectors)
         sum += sinogram[projectionInd * numberOfDetectors + t];
   }
   image[x + y * numberOfPixels] = sum * M_PI / numberOfProjections * scale;
}

__global__ void backProjectNearest3D(const float* const __restrict__ sinogram,
      float* __restrict__ image, const int numberOfPixels,
      const int numberOfProjections, const int numberOfDetectors) {

   const auto x = ddrf::cuda::getX();
   const auto y = ddrf::cuda::getY();
   const auto z = ddrf::cuda::getZ();

   if (x >= numberOfPixels || y >= numberOfPixels || z >= numberOfProjections)
      return;

   const int WARP_SIZE = 32;

   __shared__ float sumValues[WARP_SIZE];

   float sum = 0.0;

   const float scale = numberOfPixels / (float) numberOfDetectors;
   const int centerIndex = numberOfDetectors * 0.5;

   const float xp = (x - (numberOfPixels - 1.0) * 0.5) / scale;
   const float yp = (y - (numberOfPixels - 1.0) * 0.5) / scale;

   const int t = round(xp * cosLookup[z] + yp * sinLookup[z]) + centerIndex;
   if (t >= 0 && t < numberOfDetectors)
      sum = sinogram[z * numberOfDetectors + t];
   atomicAdd(&image[x + y * numberOfPixels], sum * M_PI / numberOfProjections * scale);
}

}
}