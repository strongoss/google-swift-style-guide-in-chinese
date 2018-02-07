// RUN: %target-swift-frontend -Xllvm -tf-dump-intermediates -O -emit-sil -verify %s
// RUN: %target-swift-frontend -Xllvm -tf-dump-intermediates -O -emit-sil -verify %s | %FileCheck %s
import TensorFlow

// This test is intended to verify that all of the operations end up in the
// graph: that there are no host/accelerator copies generated.  This tests a
// combination of the partitioning pass being able to recognize various forms,
// but also checks that certain ops implementations are promotable as well.

// Please keep it so no errors or warnings are generated by functions in this
// file.


public func testSelect(conds1: Tensor<Bool>, x1: Tensor<Float>, y1: Tensor<Float>)
  -> Tensor<Float> {
  let conds = conds1.toDevice()
  let x = x1.toDevice()
  let y = y1.toDevice()

  let result = conds.selecting(x+x, y)*y

  return result.toHost()
}

/*
 CHECK-LABEL: --- TFPartition Accelerator Result: {{.*}}testSelect
 CHECK: sil private @{{.*}}testSelect{{.*}} : $@callee_owned (TensorHandle<Float>, TensorHandle<Bool>, TensorHandle<Float>) -> TensorHandle<Float> {
 CHECK: bb0(%0 : $TensorHandle<Float>, %1 : $TensorHandle<Bool>, %2 : $TensorHandle<Float>):
 CHECK-NEXT:  %3 = builtin "__tfop_Add,tt:t"(%0 : $TensorHandle<Float>, %0 : $TensorHandle<Float>) : $TensorHandle<Float>
 CHECK-NEXT:  %4 = builtin "__tfop_Select,ttt:t"(%1 : $TensorHandle<Bool>, %3 : $TensorHandle<Float>, %2 : $TensorHandle<Float>) : $TensorHandle<Float>
 CHECK-NEXT: %5 = builtin "__tfop_Mul,tt:t"(%4 : $TensorHandle<Float>, %2 : $TensorHandle<Float>) : $TensorHandle<Float>
 CHECK-NEXT:  return %5 : $TensorHandle<Float>
 CHECK-NEXT:}
*/

public func testEmptyUnitsArray() {
  let y = Tensor<Int>(shape: [0, 20, 30], units: [])
  _ = y+y
}

/*
 CHECK-LABEL: --- TFPartition Accelerator Result: {{.*}}testEmptyUnitsArray
 CHECK: sil private @{{.*}}testEmptyUnitsArray{{.*}} : $@callee_owned () -> () {
 CHECK: bb0:
 CHECK: integer_literal $Builtin.Int64, 0
 CHECK: integer_literal $Builtin.Int64, 20
 CHECK: integer_literal $Builtin.Int64, 30
 CHECK:  builtin "__tfop_Const,:t,value$tensor,value$shape,$elt,$elt,$elt,dtype"({{.*}} : $@thin Int.Type, {{.*}} : $@thin Int.Type, {{.*}} : $Builtin.Int64, {{.*}} : $Builtin.Int64, {{.*}} : $Builtin.Int64, {{.*}} : $@thin Int.Type) : $TensorHandle<Int>
 CHECK:  builtin "__tfop_Add,tt:t"({{.*}} : $TensorHandle<Int>, {{.*}} : $TensorHandle<Int>) : $TensorHandle<Int>
 */


// This tests the attributes necessary to get arrays of integers and strings going.
public func testConvolution(x : Tensor<Float>, filter: Tensor<Float>) -> Tensor<Float> {
  return x.toDevice().convolved2D(withFilter: filter.toDevice(),
                       strides: [1, 2, 3, 4], padding: .same)
}

// CHECK-LABEL: --- TFPartition Accelerator Result: {{.*}}testConvolution
// CHECK: sil private @{{.*}}testConvolution{{.*}} : $@callee_owned (TensorHandle<Float>, TensorHandle<Float>) -> TensorHandle<Float> {
// CHECK: bb0(%0 : $TensorHandle<Float>, %1 : $TensorHandle<Float>):
// CHECK-NEXT:  %2 = metatype $@thin Int.Type
// CHECK-NEXT:  %3 = integer_literal $Builtin.Int64, 1
// CHECK-NEXT:  %4 = integer_literal $Builtin.Int64, 2
// CHECK-NEXT:  %5 = integer_literal $Builtin.Int64, 3
// CHECK-NEXT:  %6 = integer_literal $Builtin.Int64, 4
// CHECK-NEXT:  %7 = string_literal utf8 "SAME"
// CHECK-NEXT:  %8 = builtin "__tfop_Conv2D,tt:t,strides$array,$elt,$elt,$elt,$elt,padding"(%0 : $TensorHandle<Float>, %1 : $TensorHandle<Float>, %2 : $@thin Int.Type, %3 : $Builtin.Int64, %4 : $Builtin.Int64, %5 : $Builtin.Int64, %6 : $Builtin.Int64, %7 : $Builtin.RawPointer) : $TensorHandle<Float>
// CHECK-NEXT:  return %8 : $TensorHandle<Float>
// CHECK-NEXT:}



// Testcase for an op that uses the $tensor and $shape modifiers.
public func testConstantArray() -> TensorHandle<Float> {
  return #tfop("Const", ":t", dtype: Float.self, value$tensor: [1.0, 2.0], value$shape: [2])
}

// CHECK-LABEL: --- TFPartition Accelerator Result: {{.*}}testConstantArray
// CHECK: sil private @{{.*}}testConstantArray{{.*}} : $@callee_owned () -> TensorHandle<Float> {
// CHECK: bb0:
// CHECK-NEXT:  %0 = metatype $@thin Float.Type
// CHECK-NEXT:  %1 = metatype $@thin Double.Type
// CHECK-NEXT:  %2 = float_literal $Builtin.FPIEEE64, 0x3FF0000000000000 // 1
// CHECK-NEXT:  %3 = float_literal $Builtin.FPIEEE64, 0x4000000000000000 // 2
// CHECK-NEXT:  %4 = metatype $@thin Int.Type
// CHECK-NEXT:  %5 = integer_literal $Builtin.Int64, 2
// CHECK-NEXT:  %6 = builtin "__tfop_Const,:t,dtype,value$tensor,$elt,$elt,value$shape,$elt"(%0 : $@thin Float.Type, %1 : $@thin Double.Type, %2 : $Builtin.FPIEEE64, %3 : $Builtin.FPIEEE64, %4 : $@thin Int.Type, %5 : $Builtin.Int64) : $TensorHandle<Float>
// CHECK-NEXT:  return %6 : $TensorHandle<Float>


// Sigmoid shouldn't cause copies.  This should compile with no copy warnings/errors.
public func testSigmoid(x: Tensor<Float>, y: Tensor<Float>) -> (Tensor<Float>, Tensor<Float>) {
  let a = sigmoid(x.toDevice()).toHost()
  let b = sigmoid(y.toDevice()).toHost()
  return (a, b)
}

// Likewise, mean and max shouldn't cause send/receive errors.
public func testMeanMax(x: Tensor<Float>) -> Float {
  let y = x.toDevice()
  let a = y.mean()
  let b = y.max()
  return a+b
}

public func testZeros() -> Tensor<Float> {
  let b1 = Tensor<Float>.zeros(shape: [1, 4])
  let b2 = Tensor<Float>.zeros(shape: [1, 4])
  return (b1+b2).toHost()
}

// Here ".mean()" contains a tensor2scalar operation, and we then convert that
// scalar back to a tensor.  This checks to make sure that tf-partition can pull
// this whole mess in graph without leaving anything on the host that will cause
// a send/receive.
public func tensorToScalarToTensor(a : Tensor<Int>) -> Tensor<Int> {
  let scalar = a.toDevice().mean()
  let b = Tensor(scalar)
  return (b+b).toHost()
}


