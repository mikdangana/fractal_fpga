import numpy as np;
#from handythread import foreach;
from math import log;
from numba import cuda, njit, vectorize, jit;
from timeit import timeit



w = 1000

flat_degree = 2**8

levels = int(log(w, flat_degree))

ones = np.random.rand(w)

a = np.random.rand(w, w)
b = np.random.rand(w, w)


def matrix_test(mult_op = np.matmul, a=a, b=b):
    #res = np.matmul(a,b)
    #print(f"test().res() = {res.shape}")
    matmul = matmul_cuda_jit #njit(matmul_opt)
    def compare():
         print(f"test success = {np.all(res==matmul(a,b))}")
    x = np.array([[i*w+j for j in range(w)] for i in range(w)])
    rowx = np.ascontiguousarray(x[:,:], dtype='int32')
    rowa = np.ascontiguousarray(a[:,:], dtype='float32')
    rowb = np.ascontiguousarray(b[:,:], dtype='float32')
    #print(f"rowa = {rowa}, rowb = {rowb}")
    tnp = timeit(lambda: np.matmul(a,b), number=1)
    tjit = 0 #timeit(lambda: matmul_cuda(a,b), number=1)
    tvec = timeit(lambda: matmul_cuda_vectorize(rowa, rowb), number=1)
    tvec1 = timeit(lambda: matmul_cuda_vectorize_coord(rowx), number=1)
    tthr = timeit(lambda: matmul_threads(a,b), number=1)
    print(f"time numpy={tnp} s vs cuda={tvec} s, cuda1={tvec1} vs thr={tthr} s")



def matmul_threads(a, b):
    #def add_opt(a, degree=16):
    #a1 = add_opt(np.array(np.array([a[0] for i in range(a.shape[0])])*b[:,0]).T, 12)
    w = a.shape[0]
    #a1 = add_opt(np.array(np.array([a[0] for i in range(w)])*b).T)
    #a1 = [np.array([a[int(j)] for i in range(w)])*b for j in range(1)] 
    #a1 = np.array(a1)
    def mult(i):
        return i #np.array(a[0,:]*b[:,0].T)[0]
    umult = np.frompyfunc(mult, 1, 1)
   # a1 = np.linspace(0,w*w, num=w*w).reshape((w,w))
    x = np.arange(0,w*w,1).reshape((w,w)); 
    i=np.mod(x,w); j=np.floor(x/w).astype(np.int32);
    res = a[i,j] #umult(np.mod(x,w))
    #a1 = add_opt(a[0]*b[:,0].T, 12)
    #print(f"a[0] = {a[0].shape}, a1 = {a1.shape}")
    #res = umult(a1)
    print(f"matmul_threads().res.shape={res.shape}")
    return res



@vectorize(['float32(float32, float32)'], target='cuda')
def matmul_cuda_vectorize(a, b):
    return a*b



@vectorize(['float32(int32)'], target='cuda')
def matmul_cuda_vectorize_coord(ij):
    i, j = int(ij/w), ij%w
    return a[i,j]



# *Correct Matmul cuda.jit
# https://towardsdatascience.com/cuda-by-numba-examples-1-4-e0d06651612f


a0, a1, b0, b1 = 1000, 1000, 1000, 1000
rnd = np.random.rand(a0, a1)
tmp = 1 #cuda.device_array((a1,), np.float32)
res = 1, #cuda.device_array((a0,b1), dtype=np.float)
a, b = 1, 1, #cuda.device_array_like(rnd), cuda.device_array_like(rnd)
#print(f"a = {a}, {len(a)}, {a.shape}, {a[0,0]}")


def matmul_cuda(ma,mb):
    tmp = cuda.device_array((ma.shape[1],), np.float64)
    res = cuda.device_array((ma.shape[0],mb.shape[1]), dtype=np.float)
    a, b = cuda.device_array_like(ma), cuda.device_array_like(mb)
    for i in range(100):
        matmul_cuda_jit[a.shape[0],b.shape[1]](a, b, tmp, res)
    #res = dev.copy_to_host()
    #print(f"matmul_cuda().res = {dev.copy_to_host().shape}")
    return 1


@cuda.jit
def matmul_cuda_jit(da, db, dtmp, dres):
    i, j = cuda.grid(2)
    base, ksum = 10, 0
    #res[i,j]=sum_cuda([a[i,0] * b[0,j], a[i,1] * b[1,j], a[i,2] * b[2,j] ],10)
    mult[da[i].shape[0]](da, db, dtmp)
    #for n in range(da[i].shape[0]):
    #    dtmp[n] = da[i][n] * db[j][n]
    dres[i,j] = fsum(dtmp, 10)


@cuda.jit
def mult(da_i, db_j, dtmp):
    i = cuda.grid()
    dtmp[i] = da_i[i,0] * db_j[0,i]


@cuda.jit("int64(float64[:], int64)", device=True)
def fsum(a, degree):
    if a.shape[0] < 2: # and end>=0 and start>=0:
        return a[0] if a.shape[0]>0 else 0
    else:
        mid = round(a.shape[0]/degree)
        #mid = round(len(a)/degree)
        return fsum(a[mid*0:mid*1], degree) + \
               fsum(a[mid*1:mid*2], degree) + \
               fsum(a[mid*2:mid*3], degree) + \
               fsum(a[mid*3:mid*4], degree) + \
               fsum(a[mid*4:mid*5], degree) + \
               fsum(a[mid*5:mid*6], degree) + \
               fsum(a[mid*6:mid*7], degree) + \
               fsum(a[mid*7:mid*8], degree) + \
               fsum(a[mid*8:mid*9], degree) + \
               fsum(a[mid*9:mid*10], degree) 
        #return sum(a[mid*0:mid*(1)], degree) + \
        #       sum(a[mid*1:mid*(2)], degree) 


def sum_old(a,b,i,j,base):
    ksum = 0
    for k in range(b.shape[1]/base):
        ksum += a[i,k+0] * b[k+0,j] +  \
                a[i,k+1] * b[k+1,j] +  \
                a[i,k+2] * b[k+2,j] +  \
                a[i,k+3] * b[k+3,j] +  \
                a[i,k+4] * b[k+4,j] +  \
                a[i,k+5] * b[k+5,j] +  \
                a[i,k+6] * b[k+6,j] +  \
                a[i,k+7] * b[k+7,j] +  \
                a[i,k+8] * b[k+8,j] +  \
                a[i,k+9] * b[k+9,j]
    #    k = l * 10
    #    ksum = ksum + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j] + a[i,k] * b[k,j]
    #q = [a[i,0] * b[0,j], a[i,1] * b[1,j], a[i,2] * b[2,j] ]
    #res[i,j] = a[i,0]*b[0,j] #res[i,j][0] #[a[i, k] * b[k, j] for k in range(a.shape[1])][0]
               # c[0, k] = a[i, k] * b[k, j]
        #    res[i,j] = add_opt(c, 10)
    #res.append(c)
    #print(f"matmul_cuda_jit().res = {res.shape}")
    return ksum


@jit(nopython=True, parallel=True)
def sum_cuda(a, degree=2):
    if len(a) < 2:
        return a[0] if len(a) else 0
    else:
        mid = round(len(a)/degree)
        return sum_cuda(a[mid*0:mid*(1)], degree) + \
               sum_cuda(a[mid*1:mid*(2)], degree) 


def scratch(a, mid, degree):
        #return np.sum([add_opt(a[mid*i:mid*(i+1)], degree) for i in range(3)])
        return sum_cuda(a[mid*0:mid*(1)], degree) + \
               sum_cuda(a[mid*1:mid*(2)], degree) + \
               sum_cuda(a[mid*2:mid*(3)], degree) + \
               sum_cuda(a[mid*3:mid*(4)], degree) + \
               sum_cuda(a[mid*4:mid*(5)], degree) + \
               sum_cuda(a[mid*5:mid*(6)], degree) + \
               sum_cuda(a[mid*6:mid*(7)], degree) + \
               sum_cuda(a[mid*7:mid*(8)], degree) + \
               sum_cuda(a[mid*8:mid*(9)], degree) + \
               sum_cuda(a[mid*9:mid*(10)], degree) 

        

def add_opt_flat(a, degree=2):
    #a = np.add(a, ones)
    #for l in range(levels):
    a = a[4]
    #    a[mask[l][0]] = a[mask[l][1]] + a[mask[l][2]]
    #    a = ones #np.add(a, ones)
    #    #print(f"add_opt_flat.l = {l}")
    return a


def pad(a, minr=1):
    res = np.append(a, np.zeros((max(minr-a.shape[0],0), w)))
    res = res.reshape(int(res.shape[0]/w),w) if len(res)>1 else res
    return res


def rsum(a):
    a = np.array(a)
    #print(f"rsum().a = {a.shape}")
    return pad(a[0:1])+pad(a[1:2])+pad(a[2:3])+pad(a[3:4])+pad(a[4:5]) \
            +pad(a[5:6]) \
            +pad(a[6:7])+pad(a[7:8])+pad(a[8:9])+pad(a[9:10]) \
            +pad(a[10:11])+pad(a[11:12])+pad(a[12:13])+pad(a[13:14])


def add_opt(a, degree=16):
    if len(a) < degree:
        #return np.sum(a)
        res = rsum(a)
        return res
    else:
        mid = round(len(a)/degree)
        return rsum([add_opt(a[mid*i:mid*(i+1)], degree) for i in range(3)])


def sum_test(mult_op = np.matmul):
   # w = 100000
    a = np.random.rand(w)
    b = np.random.rand(w)
    res = np.sum(a)
    print(f"sum_test.a = {a[-10:]}, {len(a)}, res = {res}")
    def compare():
        np.sum(a)
        #print(f"test success = {np.all(res==np.sum(a))}")
    def dummy():
        return 1
    tgpu0 = timeit(dummy, number=1)
    tgpu01 = timeit(lambda: a[0:10]+1, number=1)
    tgpu = timeit(lambda: np.sum(a), number=1)
    tgpu1 = [(d, timeit(lambda: add_opt(a,2**(d+1)), number=1)) \
             for d in range(20)]
    d, t = min(tgpu1, key=lambda p: p[1])
    print(f"d = {d}, {t}")
    for i in range(1):
        tgpu2 = timeit(lambda: add_opt(a, 2**(d+1)), number=1)
    tgpu3 = timeit(lambda: add_opt_flat(a, flat_degree), number=1)
    print(f"time taken dummy = {tgpu0} s")
    print(f"time taken dummy1 = {tgpu01} s")
    print(f"regular = {tgpu} s")
    print(f"optimized = {tgpu1}, {tgpu2} s")
    print(f"speedup = {tgpu2/tgpu*100}%, {round(tgpu/tgpu2)}x, d = {d}")
    #print(f"flat = {tgpu3} s")



if __name__ == "__main__":
    #sum_test()
    matrix_test()
    #print(sum_cuda([i for i in range(10)]))
