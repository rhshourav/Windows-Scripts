rm -rf libwebp-0.5.0
tar -xf libwebp-0.5.0.tar.gz
cd libwebp-0.5.0
./configure --prefix=$PREFIX
make install CFLAGS='-O2 -mstackrealign'
