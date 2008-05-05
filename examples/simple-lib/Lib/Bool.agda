
module Lib.Bool where

open import Lib.Logic

data Bool : Set where
  true  : Bool
  false : Bool

{-# BUILTIN BOOL Bool #-}
{-# BUILTIN TRUE true #-}
{-# BUILTIN FALSE false #-}

isTrue : Bool -> Set
isTrue true  = True
isTrue false = False

if_then_else_ : {A : Set} -> Bool -> A -> A -> A
if true  then x else y = x
if false then x else y = y

not : Bool -> Bool
not true  = false
not false = true

infixr 25 _&&_
infixr 22 _||_

_&&_ : Bool -> Bool -> Bool
false && y = false
true  && y = y

_||_ : Bool -> Bool -> Bool
false || y = y
true  || y = true
