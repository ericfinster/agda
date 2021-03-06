{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-| Names in the concrete syntax are just strings (or lists of strings for
    qualified names).
-}
module Agda.Syntax.Concrete.Name where

#if MIN_VERSION_base(4,11,0)
import Prelude hiding ((<>))
#endif

import Control.DeepSeq

import Data.ByteString.Char8 (ByteString)
import Data.Function
import qualified Data.List as List
import Data.Data (Data)
import Data.Maybe

import GHC.Generics (Generic)

import System.FilePath

import Agda.Syntax.Common
import Agda.Syntax.Position

import Agda.Utils.FileName
import Agda.Utils.List
import Agda.Utils.Pretty
import Agda.Utils.Size

#include "undefined.h"
import Agda.Utils.Impossible

{-| A name is a non-empty list of alternating 'Id's and 'Hole's. A normal name
    is represented by a singleton list, and operators are represented by a list
    with 'Hole's where the arguments should go. For instance: @[Hole,Id "+",Hole]@
    is infix addition.

    Equality and ordering on @Name@s are defined to ignore range so same names
    in different locations are equal.
-}
data Name
  = Name Range [NamePart]  -- ^ A (mixfix) identifier.
  | NoName Range NameId    -- ^ @_@.
  deriving Data

-- | An open mixfix identifier is either prefix, infix, or suffix.
--   That is to say: at least one of its extremities is a @Hole@

isOpenMixfix :: Name -> Bool
isOpenMixfix n = case n of
  Name _ (x : xs@(_:_)) -> x == Hole || last xs == Hole
  _                     -> False

instance Underscore Name where
  underscore = NoName noRange __IMPOSSIBLE__
  isUnderscore NoName{}        = True
  isUnderscore (Name _ [Id x]) = isUnderscore x
  isUnderscore _               = False

-- | Mixfix identifiers are composed of words and holes,
--   e.g. @_+_@ or @if_then_else_@ or @[_/_]@.
data NamePart
  = Hole       -- ^ @_@ part.
  | Id RawName  -- ^ Identifier part.
  deriving (Data, Generic)

-- | Define equality on @Name@ to ignore range so same names in different
--   locations are equal.
--
--   Is there a reason not to do this? -Jeff
--
--   No. But there are tons of reasons to do it. For instance, when using
--   names as keys in maps you really don't want to have to get the range
--   right to be able to do a lookup. -Ulf

instance Eq Name where
    Name _ xs  == Name _ ys  = xs == ys
    NoName _ i == NoName _ j = i == j
    _          == _          = False

instance Ord Name where
    compare (Name _ xs)  (Name _ ys)  = compare xs ys
    compare (NoName _ i) (NoName _ j) = compare i j
    compare (NoName {})  (Name {})    = LT
    compare (Name {})    (NoName {})  = GT

instance Eq NamePart where
  Hole  == Hole  = True
  Id s1 == Id s2 = s1 == s2
  _     == _     = False

instance Ord NamePart where
  compare Hole    Hole    = EQ
  compare Hole    (Id {}) = LT
  compare (Id {}) Hole    = GT
  compare (Id s1) (Id s2) = compare s1 s2

-- | @QName@ is a list of namespaces and the name of the constant.
--   For the moment assumes namespaces are just @Name@s and not
--     explicitly applied modules.
--   Also assumes namespaces are generative by just using derived
--     equality. We will have to define an equality instance to
--     non-generative namespaces (as well as having some sort of
--     lookup table for namespace names).
data QName
  = Qual  Name QName -- ^ @A.rest@.
  | QName Name       -- ^ @x@.
  deriving (Data, Eq, Ord)

instance Underscore QName where
  underscore = QName underscore
  isUnderscore (QName x) = isUnderscore x
  isUnderscore Qual{}    = False

-- | Top-level module names.  Used in connection with the file system.
--
--   Invariant: The list must not be empty.

data TopLevelModuleName = TopLevelModuleName
  { moduleNameRange :: Range
  , moduleNameParts :: [String]
  }
  deriving (Show, Data)

instance Eq    TopLevelModuleName where (==)    = (==)    `on` moduleNameParts
instance Ord   TopLevelModuleName where compare = compare `on` moduleNameParts
instance Sized TopLevelModuleName where size    = size     .   moduleNameParts

------------------------------------------------------------------------
-- * Operations on 'Name' and 'NamePart'
------------------------------------------------------------------------

nameToRawName :: Name -> RawName
nameToRawName = prettyShow

nameParts :: Name -> [NamePart]
nameParts (Name _ ps)  = ps
nameParts (NoName _ _) = [Id "_"] -- To not return an empty list

nameStringParts :: Name -> [RawName]
nameStringParts n = [ s | Id s <- nameParts n ]

-- | Parse a string to parts of a concrete name.
--
--   Note: @stringNameParts "_" == [Id "_"] == nameParts NoName{}@

stringNameParts :: String -> [NamePart]
stringNameParts "_" = [Id "_"]   -- NoName
stringNameParts s = loop s where
  loop ""                              = []
  loop ('_':s)                         = Hole : loop s
  loop s | (x, s') <- break (== '_') s = Id (stringToRawName x) : loop s'

-- | Number of holes in a 'Name' (i.e., arity of a mixfix-operator).
class NumHoles a where
  numHoles :: a -> Int

instance NumHoles [NamePart] where
  numHoles = length . filter (== Hole)

instance NumHoles Name where
  numHoles NoName{}       = 0
  numHoles (Name _ parts) = numHoles parts

instance NumHoles QName where
  numHoles (QName x)  = numHoles x
  numHoles (Qual _ x) = numHoles x

-- | Is the name an operator?

isOperator :: Name -> Bool
isOperator (NoName {}) = False
isOperator (Name _ ps) = length ps > 1

isHole :: NamePart -> Bool
isHole Hole = True
isHole _    = False

isPrefix, isPostfix, isInfix, isNonfix :: Name -> Bool
isPrefix  x = not (isHole (head xs)) &&      isHole (last xs)  where xs = nameParts x
isPostfix x =      isHole (head xs)  && not (isHole (last xs)) where xs = nameParts x
isInfix   x =      isHole (head xs)  &&      isHole (last xs)  where xs = nameParts x
isNonfix  x = not (isHole (head xs)) && not (isHole (last xs)) where xs = nameParts x


------------------------------------------------------------------------
-- * Printing names which are not in scope
------------------------------------------------------------------------

-- | Prefix for things not in scope.  Cannot be the empty string.
--   Should be something unobtrusive which makes an identifier invalid.

notInScopePrefix :: String
notInScopePrefix = ";"

class MarkNotInScope a where
  -- | Prefix the first 'Id' in a name by 'notInScopePrefix' if not already present.
  markNotInScope :: a -> a
  -- | Remove the 'notInScopePrefix' if present, otherwise return 'Nothing'.
  hasNotInScopePrefix :: a -> Maybe a
  -- | Remove the 'notInScopePrefix' if present.
  removeNotInScopePrefix :: MarkNotInScope a => a -> a
  removeNotInScopePrefix x = fromMaybe x $ hasNotInScopePrefix x

instance MarkNotInScope RawName where
  markNotInScope s
    | Just{} <- hasNotInScopePrefix s = s
    | otherwise = notInScopePrefix ++ s

  hasNotInScopePrefix s
    | IsPrefix x xs <- preOrSuffix notInScopePrefix s = Just $ x:xs
    | otherwise = Nothing

instance MarkNotInScope [NamePart] where
  markNotInScope []          = []
  markNotInScope (Hole : xs) = Hole : markNotInScope xs
  markNotInScope (Id x : xs) = Id (markNotInScope x) : xs

  hasNotInScopePrefix = \case
    []        -> Nothing
    Hole : xs -> (Hole :) <$> hasNotInScopePrefix xs
    Id x : xs -> (\ x -> Id x : xs) <$> hasNotInScopePrefix x

instance MarkNotInScope Name where
  markNotInScope (Name r xs) = Name r $ markNotInScope xs
  markNotInScope x@NoName{}  = x

  hasNotInScopePrefix = \case
    Name r xs -> Name r <$> hasNotInScopePrefix xs
    NoName{}  -> Nothing

instance MarkNotInScope QName where
  markNotInScope (Qual x xs) = Qual (markNotInScope x) xs
  markNotInScope (QName x)   = QName (markNotInScope x)

  hasNotInScopePrefix = \case
    Qual x xs -> (`Qual` xs) <$> hasNotInScopePrefix x
    QName x   -> QName <$> hasNotInScopePrefix x

------------------------------------------------------------------------
-- * Operations on qualified names
------------------------------------------------------------------------

-- | @qualify A.B x == A.B.x@
qualify :: QName -> Name -> QName
qualify (QName m) x     = Qual m (QName x)
qualify (Qual m m') x   = Qual m $ qualify m' x

-- | @unqualify A.B.x == x@
--
-- The range is preserved.
unqualify :: QName -> Name
unqualify q = unqualify' q `withRangeOf` q
  where
  unqualify' (QName x)  = x
  unqualify' (Qual _ x) = unqualify' x

-- | @qnameParts A.B.x = [A, B, x]@
qnameParts :: QName -> [Name]
qnameParts (Qual x q) = x : qnameParts q
qnameParts (QName x)  = [x]

-- | Is the name qualified?

isQualified :: QName -> Bool
isQualified Qual{}  = True
isQualified QName{} = False

------------------------------------------------------------------------
-- * Operations on 'TopLevelModuleName'
------------------------------------------------------------------------

-- | Turns a qualified name into a 'TopLevelModuleName'. The qualified
-- name is assumed to represent a top-level module name.

toTopLevelModuleName :: QName -> TopLevelModuleName
toTopLevelModuleName q = TopLevelModuleName (getRange q) $ map prettyShow $ qnameParts q

-- UNUSED
-- -- | Turns a top level module into a qualified name with 'noRange'.

-- fromTopLevelModuleName :: TopLevelModuleName -> QName
-- fromTopLevelModuleName (TopLevelModuleName _ [])     = __IMPOSSIBLE__
-- fromTopLevelModuleName (TopLevelModuleName _ (x:xs)) = loop x xs
--   where
--   loop x []       = QName (mk x)
--   loop x (y : ys) = Qual  (mk x) $ loop y ys
--   mk :: String -> Name
--   mk x = Name noRange [Id x]

-- | Turns a top-level module name into a file name with the given
-- suffix.

moduleNameToFileName :: TopLevelModuleName -> String -> FilePath
moduleNameToFileName (TopLevelModuleName _ []) ext = __IMPOSSIBLE__
moduleNameToFileName (TopLevelModuleName _ ms) ext =
  joinPath (init ms) </> last ms <.> ext

-- | Finds the current project's \"root\" directory, given a project
-- file and the corresponding top-level module name.
--
-- Example: If the module \"A.B.C\" is located in the file
-- \"/foo/A/B/C.agda\", then the root is \"/foo/\".
--
-- Precondition: The module name must be well-formed.

projectRoot :: AbsolutePath -> TopLevelModuleName -> AbsolutePath
projectRoot file (TopLevelModuleName _ m) =
  mkAbsolute $
  foldr (.) id (replicate (length m - 1) takeDirectory) $
  takeDirectory $
  filePath file

------------------------------------------------------------------------
-- * No name stuff
------------------------------------------------------------------------

-- | @noName_ = 'noName' 'noRange'@
noName_ :: Name
noName_ = noName noRange

noName :: Range -> Name
noName r = NoName r (NameId 0 0)

-- | Check whether a name is the empty name "_".
class IsNoName a where
  isNoName :: a -> Bool

instance IsNoName String where
  isNoName = isUnderscore

instance IsNoName ByteString where
  isNoName = isUnderscore

instance IsNoName Name where
  isNoName (NoName _ _)    = True
  isNoName (Name _ [Hole]) = True   -- TODO: Track down where these come from
  isNoName (Name _ [])     = True
  isNoName (Name _ [Id x]) = isNoName x
  isNoName _               = False

instance IsNoName QName where
  isNoName (QName x) = isNoName x
  isNoName Qual{}    = False        -- M.A._ does not qualify as empty name

-- no instance for TopLevelModuleName

------------------------------------------------------------------------
-- * Showing names
------------------------------------------------------------------------

-- deriving instance Show Name
-- deriving instance Show NamePart
-- deriving instance Show QName

-- TODO: 'Show' should output Haskell-parseable representations.
-- The following instances are deprecated, and Pretty should be used
-- instead.  Later, simply derive Show for these types:

instance Show Name where
  show = prettyShow

instance Show NamePart where
  show = prettyShow

instance Show QName where
  show = prettyShow

------------------------------------------------------------------------
-- * Printing names
------------------------------------------------------------------------

instance Pretty Name where
  pretty (Name _ xs)  = hcat $ map pretty xs
  pretty (NoName _ _) = text $ "_"

instance Pretty NamePart where
  pretty Hole   = text $ "_"
  pretty (Id s) = text $ rawNameToString s

instance Pretty QName where
  pretty (Qual m x)
    | isUnderscore m = pretty x -- don't print anonymous modules
    | otherwise      = pretty m <> pretty "." <> pretty x
  pretty (QName x)  = pretty x

instance Pretty TopLevelModuleName where
  pretty (TopLevelModuleName _ ms) = text $ List.intercalate "." ms

------------------------------------------------------------------------
-- * Range instances
------------------------------------------------------------------------

instance HasRange Name where
    getRange (Name r ps)  = r
    getRange (NoName r _) = r

instance HasRange QName where
    getRange (QName  x) = getRange x
    getRange (Qual n x) = fuseRange n x

instance HasRange TopLevelModuleName where
  getRange = moduleNameRange

instance SetRange Name where
  setRange r (Name _ ps)  = Name r ps
  setRange r (NoName _ i) = NoName r i

instance SetRange QName where
  setRange r (QName x)  = QName (setRange r x)
  setRange r (Qual n x) = Qual (setRange r n) (setRange r x)

instance SetRange TopLevelModuleName where
  setRange r (TopLevelModuleName _ x) = TopLevelModuleName r x

instance KillRange QName where
  killRange (QName x) = QName $ killRange x
  killRange (Qual n x) = killRange n `Qual` killRange x

instance KillRange Name where
  killRange (Name r ps)  = Name (killRange r) ps
  killRange (NoName r i) = NoName (killRange r) i

instance KillRange TopLevelModuleName where
  killRange (TopLevelModuleName _ x) = TopLevelModuleName noRange x

------------------------------------------------------------------------
-- * NFData instances
------------------------------------------------------------------------

-- | Ranges are not forced.

instance NFData Name where
  rnf (Name _ ns)  = rnf ns
  rnf (NoName _ n) = rnf n

instance NFData NamePart where
  rnf Hole   = ()
  rnf (Id s) = rnf s

instance NFData QName where
  rnf (Qual a b) = rnf a `seq` rnf b
  rnf (QName a)  = rnf a
