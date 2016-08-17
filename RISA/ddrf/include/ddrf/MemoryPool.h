/*
 * MemoryPool.h
 *
 *  Created on: 01.05.2016
 *      Author: Tobias Frust (t.frust@hzdr.de)
 */

#ifndef MEMORYPOOL_H_
#define MEMORYPOOL_H_

#include "Singleton.h"
#include "Image.h"

#include <boost/log/trivial.hpp>

#include <vector>
#include <mutex>
#include <condition_variable>
#include <exception>
#include <memory>

namespace ddrf {

template<class MemoryManager>
class Image;

template<class MemoryManager>
class MemoryPool: public Singleton<MemoryPool<MemoryManager>>, MemoryManager {

	friend class Singleton<MemoryPool<MemoryManager>> ;
public:
	//forward declaration
	using type = ddrf::Image<MemoryManager>;

	/**
	 * All stages that are registered in MemoryPool can request memory with
	 * this function. If the stage is not registered, an exception will be thrown.
	 * Memory allocation occurs only, if stage did not request enough memory
	 * during registration. In all other cases no allocation, no copy operations
	 * will be performed.
	 *
	 * @param[in] idx stage that requests memory, got an id during registration.
	 *            This id needs to passed to this function.
	 */
	auto requestMemory(unsigned int idx) -> type {
		//std::lock_guard<std::mutex> lock(memoryManagerMutex_);
      auto lock = std::unique_lock<std::mutex>{memoryManagerMutex_};
		if(memoryPool_.size() <= idx)
		    throw std::runtime_error("cuda::MemoryPool: Stage needs to be registered first.");
		while(memoryPool_[idx].empty()){
		   cv_.wait(lock);
		}
		auto ret = std::move(memoryPool_[idx].back());
		memoryPool_[idx].pop_back();
		return ret;
	}

	/**
	 * This function gets an image, e.g. when image gets out of scope
	 * and stores it in the memory pool vector, where it originally
	 * came from
	 *
	 * @param[in] img Image, that shall be returned into memory pool for reuse
	 *
	 */
	auto returnMemory(type&& img) -> void {
		if(memoryPool_.size() <= img.memoryPoolIndex())
		   throw std::runtime_error("cuda::MemoryPool: Stage needs to be registered first.");
      std::lock_guard<std::mutex> lock{memoryManagerMutex_};
		memoryPool_[img.memoryPoolIndex()].push_back(std::move(img));
		cv_.notify_one();
	}

	/**
	 * All stages that need memory need to register in MemoryManager.
	 * Stages need to tell, which size of memory they need and how many elements.
	 * The MemoryManager then allocates the memory and manages it.
	 *
	 * @param[in] numberOfElements 	number of elements that shall be allocated by the MemoryManager
	 * @param[in] size				size of memory that needs to be allocated per element
	 *
	 * @return identifier, where
	 *
	 */
	auto registerStage(const int& numberOfElements,
			const size_t& size) -> int {
		//lock, to ensure thread safety
	   std::lock_guard<std::mutex> lock(memoryManagerMutex_);
		std::vector<type> memory;
		int index = memoryPool_.size();
		for(int i = 0; i < numberOfElements; i++) {
			auto img = type {};
			auto ptr = MemoryManager::make_ptr(size);
			img = type {size, 0, 0, std::move(ptr)};
			img.setMemPoolIdx(index);
			memory.push_back(std::move(img));
		}
		memoryPool_.push_back(std::move(memory));
		return index;
	}

	auto freeMemory(const unsigned int idx) -> void {
	   for(auto& ele: memoryPool_[idx]){
	      ele.invalid();
	   }
	   memoryPool_[idx].clear();
	}

private:
	~MemoryPool() = default;

	MemoryPool() = default;

private:
	std::vector<std::vector<type>> memoryPool_;
	mutable std::mutex memoryManagerMutex_;
	std::condition_variable cv_;
};


}

#endif /* MEMORYPOOL_H_ */