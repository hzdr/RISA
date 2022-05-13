### !!! Development moved to [GitLab](https://gitlab.hzdr.de/risa/RISA) !!!

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.200363.svg)](https://doi.org/10.5281/zenodo.200363)

# RISA - Rofex In-Situ Analysis

### Documentation to be found at: https://hzdr-fwdf.github.io/RISA/index.html

Prerequisites:
- cmake (>= 3.5)
- CUDA and compatible host compiler (e.g. gcc)
- libconfig++
- Boost (>= 1.58)
- LibTiff

Installation on Ubuntu 16.04
- install libConfig:
    ```sudo apt-get install libconfig++-dev```
- install cmake:
    ```sudo apt-get install cmake cmake-curses-gui```
- install boost:
    ```sudo apt-get install libboost-all-dev```
- install libtiff:
    ```sudo apt-get install libtiff5-dev```
- install CUDA (download from NVIDIA homepage: https://developer.nvidia.com/cuda-toolkit and follow the  instructions)
- in order to build the documentation, ```doxygen``` and ```graphviz``` need to be installed
    ```sudo apt install doxygen graphviz```

Building the software:
- If the software is built for another CUDA device architecture, this architecture needs to be added in the top-level CmakeLists.txt
- create a new path, outside of src-directory, called e.g. 'build'
- move into this path and enter following command in terminal:
    ```ccmake <path_to_src>```
    e.g.
    ```ccmake ../RISA/.```
- check if everything could be found and enter ```CMAKE_BUILD_TYPE```, options are:
    ```Debug, RelWithDebInfo, Release```
- if everything worked out, make the project
    ```make -j all```
- if build was successful, there is an executable in the ```build/bin``` folder
- the documentation can be found in the ```doc/html``` folder

Running the software:
- first the configuration file in the example directory needs to be adapted. Especially the paths to the input data.
- the software can be invoked by issuing the following command:
    ```./example <path_to_configuration_file>```
