/**************************************************
 *  All-pairs-shortest paths
 *	Host code.
 *  Recursive in-place implementation 
 *  Copyright by Ceren Budak, Aydin Buluc, Fenglin Liao, Arda Atali
 *  NOTES: Continues the recursion until all of the problem fits into one block.  
 *  DATE:  December 2007
 *  ROW-WISE (OLD) TIMINGS: [Max BLOCK_SIZE possible is 16]
  ~5100/5900 ms with 4K vertices and BLOCK_SIZE=16
  ~7500 ms with 4K vertices and BLOCK_SIZE=8
 *  COL-WISE (NEW) TIMINGS: [Using Volkov's GEMM]
  ~1014 ms with 4K vertices
 ***************************************************/
 
 /** 
 * An implementation of the recursive APSP algorithm
 * A is an adjacency matrix of a graph, nonzeros represents edge, zeros represent no edges
 * Matrices are laid out in column-major order
 */

#include "device_functions.h"
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

// System includes
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <limits.h>

// Project includes
//#include <cutil.h>
#include <common_functions.h>

// Kernel includes
#include "apsp_kernel.h"

using namespace std;


void runTest(int argc, char** argv);
void printDiff(float *, float*, int, int);
void floydWarshall(float *, int, int);

extern "C"
void computeGoldCol(float *, const float *, unsigned int);



int main(int argc, char** argv)
{
    runTest(argc, argv);

    //CUT_EXIT(argc, argv);
}


void
GenerateErdosRenyiGraph(float** graph, unsigned size, unsigned average_degree) {
  unsigned num_elements = size * size;
  *graph = (float*) malloc(num_elements * sizeof(float));
  float* g = *graph;

  unsigned i;
  unsigned j;
  for(i = 0; i < size; ++i) {
    for (j = 0; j < size; ++j) {
      if (i != j) {
        unsigned rv = rand() % average_degree; // TODO: account for self edge
        if (rv == 0) {
          g[i * size + j] = (float) (rand() % 10) + 1.0;
        } else {
          g[i * size + j] = FLOATINF;
        }
      } else {
        g[i * size + j] = 0;
      }
    }
  }
}



#include <math.h>
#include <vector>
struct triple {
  unsigned i;
  unsigned j;
  float one;
  float other;
};

bool
GraphsAreEquivalent(float* one, float* other, unsigned size, float tolerance) {
/**
 *
 */
  unsigned i, j, k;
  for (i = 0; i < size * size; ++i) {
    if (fabs(one[i] - other[i]) > tolerance) {
      return false;
    }
  }

  return true;
}


 bool
 GraphsAreEquivalentDefault(float* one, float* other, unsigned size) {
   return GraphsAreEquivalent(one, other, size, 0.001);
 }


void Load(FILE * fid, float * distMatrix, int size)
{
  int read = 0;
  int v1, v2;
  float value;
  
  for (int j=0; j<WA; j++) 
    for (int i=0; i<WA; i++) 
      distMatrix[j*WA+i] = FLOATINF;

  while (read < size)
  {
    if(fscanf(fid, "%d\t%d\t%f\n", &v1,&v2,&value) == EOF)
    {
      fprintf(stderr,"Error reading file when reading %d of %d\n", read, size);
      exit(1);
    }
    
    v1--;
    v2--;
    
    distMatrix[v2*WA + v1] = fabs(value)*1000;		// column-major
    read++;
  }
  for (int i=0; i<WA; i++)
    distMatrix[i*WA + i] = 0;	// diagonals are zero
    
  fclose(fid); 
}


void runTest(int argc, char** argv)
{
    printf("Final APSP Optimized (column-major)\n");
    //CUT_DEVICE_INIT();

    // allocate host memory for matrices A
    unsigned int size_A = WA * WA;
    unsigned int mem_size_A = sizeof(float) * size_A;
    //float * h_A = (float*) malloc(mem_size_A);

    // Initialize host memory by reading the matrix from file
    
  //  FILE * fp;
  //  if((fp=fopen("rmat.txt", "r")) == NULL) 
  //  {
  //printf("Cannot open file.\n");
  //exit(1);
  //  }
  //  int m,n, nnz;
  //  if(fscanf(fp, "%d\t%d\t%d\n", &m,&n,&nnz) == EOF)
  //  {
  //fprintf(stderr,"Error reading file\n");
  //exit(1);
  //  }
  //  
  //  Load(fp, h_A, nnz);
    float* h_A;
    GenerateErdosRenyiGraph(&h_A, WA, 6);


    puts("doin' the device");
    // allocate device memory (since the algorithm is in-place, no memory required for the output)
    float * d_A;
    cudaMalloc((void**) &d_A, mem_size_A);

    // copy host memory to device
    cudaMemcpy(d_A, h_A, mem_size_A, cudaMemcpyHostToDevice);

    

    // call our recursive function
    floydWarshall(d_A,0, WA);

    
    // call synchronize before stopping the timer
    cudaThreadSynchronize();
    
    // allocate mem for the result on host side
    float * h_C = (float*) malloc(mem_size_A);

    // copy result from device to host
    cudaMemcpy(h_C, d_A, mem_size_A, cudaMemcpyDeviceToHost);

    puts("device finished");

#define VERIFY 0
#ifdef VERIFY
    // compute reference solution
   fprintf(stderr, "Computing on the CPU (for verification)\n");
   float* reference = (float*) malloc(mem_size_A);

    computeGoldCol(reference, h_A, WA);
   
    if (GraphsAreEquivalent(reference, h_C, WA, 0.1)) {
      puts("we're good!");
    } else {
      puts("HOLD ON - SOMETHING DOESN'T MATCH UP!!!");
    }

    // check result
    printDiff(reference, h_C, WA, WA);
    free(reference);
#endif

    // clean up memory
    free(h_A);
    free(h_C);
    cudaFree(d_A);
}


// recursive calls are only made to diagonal blocks, i.e. start = startx = starty

void floydWarshall(float *data, int start, int width)
{
  if(width <= BLOCK_SIZE)
  {
      // setup execution parameters
        
      // the computation now can fit in one block
      dim3 threads(width, width);
      dim3 grid(1, 1);
        
      // execute the kernel with a single block
      apsp_seq<<< grid, threads >>>(data, width,start);
  }
  else if(width <= FAST_GEMM)	
  {
    int nw = width/2;		// new width
      
    // setup execution parameters
    dim3 threadsmult(BLOCK_SIZE, BLOCK_SIZE);
    dim3 gridmult(nw / BLOCK_SIZE, nw / BLOCK_SIZE);
        

    // do FW for D
    floydWarshall(data, start+nw, nw);

    // execute the kernel B = BD
    matrixMul<<< gridmult, threadsmult >>>(data, data, data, nw, start+nw, start, start+nw,start,start+nw, start+nw,0);

    // execute the kernel C = DC
    matrixMul<<< gridmult, threadsmult >>>(data, data, data, nw, start, start+nw,start+nw,start+nw,start, start+nw,0);

    // execute the kernel A += BC
    matrixMul<<< gridmult, threadsmult >>>(data, data, data, nw, start,start,start+nw,start, start, start+nw,1);
 

    ///////////////////////////////////////        
    floydWarshall(data, start, nw);

    // execute the kernel B = AB
    matrixMul<<< gridmult, threadsmult >>>(data, data, data, nw, start+nw, start, start,start,start+nw, start,0);
        
    // execute the kernel C = CA
    matrixMul<<< gridmult, threadsmult >>>(data, data, data, nw, start, start+nw,start,start+nw,start, start,0);

    // execute the kernel D += CB      
    matrixMul<<< gridmult, threadsmult >>>(data, data, data, nw, start+nw,start+nw,start,start+nw, start+nw, start,1);
    //////////////////////////////////////////

  } else {
    /*A=floyd-warshall(A);
    B=AB;
    C=CA;
    D=D+CB;
    D=floyd-warshall(D);
    B=BD;
    C=DC;
    A=A+BC;*/
        
    int nw = width/2;		// new width

    // setup execution parameters
    dim3 gemmgrid( nw /64, nw/16 );
    dim3 gemmthreads( 16, 4 );



    // Remember: Column-major
    float * A = data + start * WA + start;
    float * B = data + (start+nw) * WA + start;
    float * C = data + start * WA + (start+nw);
    float * D = data + (start+nw) * WA + (start+nw);

    // sgemmNN_MinPlus( const float *A, int lda, const float *B, int ldb, float* C, int ldc, int k, float alpha, float beta )
    // no need to send m & n since they are known through grid dimensions !

    // do FW for D
    floydWarshall(data, start+nw, nw);

    // execute the parallel multiplication kernel B = BD
    sgemmNN_MinPlus<<<gemmgrid, gemmthreads>>>(B, WA, D, WA, B, WA, nw,  FLOATINF );

    // execute the parallel multiplication kernel C = DC
    sgemmNN_MinPlus<<<gemmgrid, gemmthreads>>>(D, WA, C, WA, C, WA, nw,  FLOATINF );

    // execute the parallel multiplication kernel A += BC
    sgemmNN_MinPlus<<<gemmgrid, gemmthreads>>>(B, WA, C, WA, A, WA, nw,  1 );
  
    ////////////////////////////////////////////////////////
    floydWarshall(data, start, nw);
    
    // execute the parallel multiplication kernel B = AB
    sgemmNN_MinPlus<<<gemmgrid, gemmthreads>>>(A, WA, B, WA, B, WA, nw,  FLOATINF );

    // execute the parallel multiplication kernel C = CA
    sgemmNN_MinPlus<<<gemmgrid, gemmthreads>>>(C, WA, A, WA, C, WA, nw,  FLOATINF );
        
     
    // execute the parallel multiplication kernel  D += CB 
    sgemmNN_MinPlus<<<gemmgrid, gemmthreads>>>(C, WA, B, WA, D, WA, nw,  1 );
    ///////////////////////////////////////////////////////////////////////

  }
}

void printDiff(float *data1, float *data2, int width, int height)
{
  fprintf(stderr,"Verifying...");

  int i,j,k;
  int error_count=0;
  for (i=0; i<height; i++) {
    for (j=0; j<width; j++) {
      k = i*width+j;
      if ( abs(data1[k] - data2[k]) > 0.01 ) {
         fprintf(stdout,"diff(%d,%d) CPU=%f, GPU=%f\n", i,j, data1[k], data2[k]);
         error_count++;
      }
    }
  }
  printf("\nTotal Errors = %d\n", error_count);
  
   /*	
  printf("Writing output to disk...\n"); 
 
    FILE * fp;
    if((fp=fopen("result.txt", "w")) == NULL) 
    {
    printf("Cannot open file.\n");
    exit(1);
  }
  for (int i=0; i<WA; i++) 
  {
    for (int j=0; j<WA; j++) 
    {
      if(data2[i*WA + j] != FLOATINF)
        fprintf(fp,"%d\t%d\t%f\n", i, j, data2[i*WA + j]); 
    }
  }
  
  fclose(fp);
 */
}
