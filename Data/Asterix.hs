----------------
-- |
-- Module       :  Data.Asterix
--
-- Maintainer   : Zoran Bošnjak <zoran.bosnjak@sloveniacontrol.si>
--
-- This module provides encoder/decoder for Asterix data.
--
-- This module is intended to be imported qualified, e.g.
--
-- > import qualified Data.Asterix as A
--
-- Examples:
--
--      * parse XML
--  
-- >        s <- readFile "path/to/catXY.xml"
-- >        let c = A.categoryDescription s
--
--      * parse many XML files, keep only latest revision of each defined category,
--        force evaluation
--
-- >        import Control.Exception (evaluate)
-- >        import Control.DeepSeq (force)
-- >
-- >        let args = [fileName1, fileName2,...]
-- >        s <- mapM readFile args
-- >        --  uaps <- evaluate . force . map ... TODO
--
--      * decode bits to records
--
-- >        import qualified Data.BitString as B
-- >
-- >        let datablock = B.fromIntegral 48 0x000006800203
-- >
-- >        profiles <- ...
-- >        let parse db = return db
-- >                >>= toDataBlocks
-- >                >>= mapM (toRecords profiles)
-- >                >>= return . join
-- >
-- >        print $ parse datablock
--
--          TODO
--
--      * encode
--
--          TODO
--

module Data.Asterix
(   
    -- * Data types
    Tip(..)
    , Item(..)
    , Desc(..)
    , Category(..), Edition(..), Uap

    -- * Aliases
    , UapName, ItemName, ItemDescription
    , Major, Minor
    , Cat
    , Profiles

    -- * Datablock
    , DataBlock(..)
    , toDataBlocks
    -- , datablock 

    -- * XML parsers
    , categoryDescription

    -- * UAP
    , uapByName
    , uapByData

    -- * Decode
    , toRecords

    -- * Subitem access
    , child
    , childR
    , childs

    -- * Encode

    -- * Converters: Item - Numeric value
    , toIntegral

    -- * Converters: Item - (natural value)

    -- * Util functions
    , sizeOf
    , grab

    -- * Expression evaluation
    , eval

) where

import Data.Maybe (fromMaybe, isJust)
import Data.Monoid
import qualified Data.Map as Map
import Data.Word

import Control.DeepSeq.Generics
import Control.Monad
-- import Control.Monad.State

import qualified Text.XML.Light as X
import Text.XML.Light.Lexer (XmlSource)

import qualified Data.BitString as B
import Data.Asterix.Expression (eval)

-- for debug purposes
-- import Debug.Trace
-- dump = flip trace

-- | Asterix item types
data Tip = TItem
           | TFixed
           | TSpare
           | TExtended
           | TRepetitive
           | TExplicit
           | TCompound
           -- TRfs
           deriving (Show, Read, Eq)

-- | description + data
data Item = Item {
        iDsc :: Desc 
        ,iBits :: B.Bits 
        }deriving (Show,Eq)

-- | Asterix item description
data Desc = Desc {  dName       :: ItemName
                    , dTip      :: Tip
                    , dDsc      :: ItemDescription
                    , dLen      :: Length
                    , dItems    :: [Desc]
                    , dValue    :: Value
                 } deriving (Eq)
instance NFData Desc
instance Show Desc where
    show d = (show . dTip $ d) ++ " (" ++ (dName d) ++ "), " ++ (show . dLen $ d) ++ ", " ++ (show $ dValue d)

-- | Empty description
noDesc :: Desc
noDesc = Desc {
    dName = ""
    , dTip = TItem
    , dDsc = ""
    , dLen = Length0
    , dItems = []
    , dValue = VRaw
}

type Cat = Word8
type Uap = (UapName,Desc)
type UapName = String
type ItemName = String
type ItemDescription = String
type Major = Int
type Minor = Int
type Size = Int

-- | Asterix standard (particular edition)
data Category = Category {
        cCat :: Cat 
        ,cEdition :: Edition 
        ,cUaps :: [Uap]
    }
instance NFData Category
instance Show Category where
    show c = "(category " ++ (show $ cCat c) ++ ", edition " ++ (show $ cEdition c) ++ ")"

type Profiles = Map.Map Cat Category

-- | Asterix edition
data Edition = Edition Major Minor deriving (Eq)
instance NFData Edition
instance Ord Edition where
    compare (Edition a1 b1) (Edition a2 b2) = (compare a1 a2) `mappend` (compare b1 b2)
instance Show Edition where
    show (Edition a b) = show a ++ "." ++ show b
instance Read Edition where
    readsPrec _ value = [(Edition (read a) (read b), "")] where
        a = takeWhile (/='.') value
        b = tail . dropWhile (/='.') $ value

-- | Length of asterix item
data Length = Length0 | Length1 Int | Length2 Int Int deriving (Show, Read, Eq)

type Lsb = Double
type Unit = String
type Min = Double
type Max = Double

data Value = 
    VRaw
    | VString
    | VDecimal Lsb (Maybe Unit) (Maybe Min) (Maybe Max)
    | VUnsignedDecimal Lsb (Maybe Unit) (Maybe Min) (Maybe Max)
    | VInteger (Maybe Unit) (Maybe Min) (Maybe Max)
    | VUnsignedInteger (Maybe Unit) (Maybe Min) (Maybe Max)
    deriving (Eq, Show)

data DataBlock = DataBlock {
    dbCat :: Cat
    , dbData :: B.Bits
} deriving (Eq, Show)

-- | Read xml content.
categoryDescription :: XmlSource s => s -> Either String Category
categoryDescription src = do
    let elements = X.onlyElems . X.parseXML $ src
     
    category <- case filter (\e -> (X.qName . X.elName $ e) == "category") $ elements of
                    [] -> Left "<category> not found in xml"
                    (x:_) -> Right x

    cat <- getAttr category "cat"
    ed <- getAttr category "edition"

    items <- getChild category "items"
                >>= return . X.elChildren
                >>= mapM readItem
                >>= return . map (\i -> (dName i, i))

    dscr <- do
        uaps <- getChild category "uaps" >>= return . X.elChildren
        forM uaps $ \uap -> do
            uapItems <- forM (map X.strContent . X.elChildren $ uap) $ \item -> do
                case item of
                    "" -> Right noDesc
                    _ -> case (lookup item items) of
                        Nothing -> Left $ "item " ++ (show item) ++ " not found in <items>"
                        Just x -> Right x
            let uapName = X.qName . X.elName $ uap
                topLevel = Desc {
                    dName = ""
                    , dTip = TCompound
                    , dDsc = "Category " ++ (show cat)
                    , dLen = Length0
                    , dItems = uapItems
                    , dValue = VRaw
                }
            return (uapName, topLevel)

    Right $ Category {cCat=cat, cEdition=ed, cUaps=dscr} 
    
    where
        nameOf s = X.blank_name {X.qName=s}

        getAttr el aName = case X.findAttr (nameOf aName) el of
                            Nothing -> Left $ "Attribute '"++aName++ "' not found in element " ++ (show el)
                            Just x -> Right $ read x

        getChild el aName = case X.findChild (nameOf aName) el of
                            Nothing -> Left $ "Child '"++aName++ "' not found in element " ++ (show el)
                            Just x -> Right x
    
        readLength :: String -> Either String Length
        readLength s
            | s == "" = Right Length0
            | isJust (maybeRead s :: Maybe Size) = Right $ Length1 . read $ s
            | isJust (maybeRead s :: Maybe (Size,Size)) = Right $ Length2 a b
            | otherwise = Left $ "Unable to read length: " ++ s
            where
                (a,b) = read s
                maybeRead s' = case reads s' of
                    [(x, "")] -> Just x
                    _         -> Nothing

        recalculateLen :: Desc -> Length
        recalculateLen dsc = fromMaybe Length0 (total dsc >>= Just . Length1) where
            total :: Desc -> Maybe Size
            total Desc {dLen=Length1 a} = Just a
            total Desc {dLen=Length2 _ _} = Nothing
            total Desc {dItems=[]} = Just 0
            total dsc'@Desc {dItems=(i:is)} = do
                x <- total i
                rest <- total (dsc' {dItems=is})
                Just (x + rest)
        
        readItem :: X.Element -> Either String Desc
        readItem el = dsc' el >>= f where 

            -- check description, recalculate length
            f :: Desc -> Either String Desc
            f dsc@Desc {dTip=TItem, dLen=Length0, dItems=(_:_)} = Right $ dsc {dLen=recalculateLen dsc}
            f dsc@Desc {dTip=TFixed, dLen=Length1 _, dItems=[]} = Right dsc
            f dsc@Desc {dTip=TSpare, dLen=Length1 _, dItems=[]} = Right dsc
            f dsc@Desc {dTip=TExtended, dLen=Length2 _ _} = Right dsc
            f dsc@Desc {dTip=TRepetitive, dLen=Length0, dItems=(_:_)} = Right $ dsc {dLen=recalculateLen dsc}
            f dsc@Desc {dTip=TExplicit, dLen=Length0, dItems=[]} = Right dsc
            f dsc@Desc {dTip=TCompound, dLen=Length0, dItems=(_:_)} = Right dsc
            f x = Left $ "error in description: " ++ (dName x)

            -- get all elements
            dsc' e = do
                name <- case X.findAttr (nameOf "name") e of
                    Nothing -> Left $ "name not found: " ++ (show e)
                    Just n -> Right n
                tip <- return . read . ("T"++) . fromMaybe "Item" . X.findAttr (nameOf "type") $ e
                dsc <- return $ either (\_->"") (X.strContent) (getChild e "dsc")
                len <- return (either (\_->"") (X.strContent) (getChild e "len")) >>= readLength
                items <- sequence $ map readItem $ either (\_->[]) X.elChildren (getChild e "items")
                val <- getValueTip e

                Right $ Desc {dName=name, dTip=tip, dDsc=dsc, dLen=len, dItems=items, dValue=val}

            getValueTip :: X.Element -> Either String Value
            getValueTip el' = case getChild el' "convert" of
                Left _ -> Right VRaw
                Right conv -> do
                    tip <- getChild conv "type" >>= return . X.strContent

                    let tryGetChild element name = case getChild element name of
                                Left _ -> Right Nothing
                                Right ch -> Right . Just $ X.strContent ch
                        tryEval exp' = case exp' of
                                Nothing -> Right Nothing
                                Just exp'' -> case eval exp'' of
                                    Nothing -> Left $ "unable to eval " ++ exp''
                                    Just val -> Right $ Just val

                    lsb <- tryGetChild conv "lsb" >>= tryEval
                    unit <- tryGetChild conv "unit" 
                    min' <- tryGetChild conv "min" >>= tryEval
                    max' <- tryGetChild conv "max" >>= tryEval

                    case tip of
                        "string" -> Right VString
                        "decimal" -> case lsb of
                                        Nothing -> Left $ "'lsb' missing " ++ (show el')
                                        Just lsb' -> Right $ VDecimal lsb' unit min' max'
                        "unsigned decimal" -> case lsb of
                                        Nothing -> Left $ "'lsb' missing " ++ (show el')
                                        Just lsb' -> Right $ VUnsignedDecimal lsb' unit min' max'
                        "integer" -> Right $ VInteger unit min' max'
                        "unsigned integer" -> Right $ VUnsignedInteger unit min' max'
                        _ -> Right VRaw

-- | get UAP by name
uapByName :: Category -> UapName -> Maybe Desc
uapByName c name = lookup name (cUaps c)

-- | get UAP by data
uapByData :: Category -> B.Bits -> Maybe Desc
uapByData c _
    | cCat c == 1   = undefined -- TODO, cat1 is special
    | otherwise     = uapByName c "uap"

-- | Split bits to datablocks
toDataBlocks :: B.Bits -> Maybe [DataBlock]
toDataBlocks bs
    | B.null bs = Just []
    | otherwise = do
        x <- B.checkAligned bs
        cat <- return x >>= B.takeMaybe 8 >>= return . B.toIntegral
        len <- return x >>= B.dropMaybe 8 >>= B.takeMaybe 16 >>= return . B.toIntegral
        y <- return x >>= B.takeMaybe (len*8) >>= B.dropMaybe 24

        let db = DataBlock cat y
        rest <- return x >>= B.dropMaybe (len*8) >>= toDataBlocks
        Just (db:rest)

-- | Split datablock to records.
toRecords :: Profiles -> DataBlock -> Maybe [Item]
toRecords profiles db = do
    let cat = dbCat db
        d = dbData db
    category <- Map.lookup cat profiles
    getRecords category d 
    where

        getRecords :: Category -> B.Bits -> Maybe [Item]
        getRecords category bs
            | B.null bs = Just []
            | otherwise = do
                dsc <- uapByData category bs
                size <- sizeOf dsc bs
                rec <- B.takeMaybe size bs
                rest <- getRecords category (B.drop size bs)
                Just $ (Item {iDsc=dsc, iBits=rec}):rest

-- | Get fspec bits, (without fs, with fx)
getFspec :: B.Bits -> Maybe ([Bool],[Bool])
getFspec b = do
    n <- checkSize 8 b
    let val = B.unpack . B.take n $ b
    if (last val == False)
        then Just ((init val), val)
        else do
            (remin, remTotal) <- getFspec (B.drop n b)
            let rv = (init val) ++ remin
                rvTotal = val ++ remTotal
            Just (rv, rvTotal)

-- | Check that requested number of bits are available.
checkSize :: Int -> B.Bits -> Maybe Int
checkSize n b
    | B.length b < n = Nothing
    | otherwise = Just n

-- | Grab bits: bits -> (bits for item, remaining bits)
grab :: Desc -> B.Bits -> Maybe (B.Bits, B.Bits)
grab dsc b = do
    size <- sizeOf dsc b
    Just (B.take size b, B.drop size b)

-- | Calculate items size.
sizeOf :: Desc -> B.Bits -> Maybe Size

-- size of Item
sizeOf Desc {dTip=TItem, dLen=Length1 n} b = checkSize n b
sizeOf Desc {dTip=TItem, dItems=[]} _ = Just 0
sizeOf d@Desc {dTip=TItem, dItems=(i:is)} b = do
    size <- sizeOf i b
    rest <- sizeOf (d {dItems=is}) (B.drop size b)
    Just (size+rest)

-- size of Fixed
sizeOf Desc {dTip=TFixed, dLen=Length1 n} b = checkSize n b

-- size of Spare
sizeOf Desc {dTip=TSpare, dLen=Length1 n} b = do
    size <- checkSize n b
    if (B.take size b) /= (B.zeros size) 
        then Nothing
        else Just size

-- size of Extended
sizeOf Desc {dTip=TExtended, dLen=Length2 n1 n2} b = do
    size <- checkSize n1 b
    if (B.index b (size-1)) 
        then dig size
        else Just size
    where
        dig offset = do 
            size <- checkSize offset b
            if (B.index b (size-1)) 
                then dig (size+n2)
                else Just size

-- size of Repetitive
sizeOf d@Desc {dTip=TRepetitive} b = do
    s8 <- checkSize 8 b
    let rep = B.toIntegral . B.take s8 $ b
        b' = B.drop s8 b
    getSubitems rep b' 8
    where
        getSubitems :: Int -> B.Bits -> Size -> Maybe Size
        getSubitems 0 _ size = Just size
        getSubitems n b'' size = do
            itemSize <- sizeOf (d {dTip=TItem}) b''
            getSubitems (n-1) (B.drop itemSize b'') (itemSize+size)

-- size of Explicit
sizeOf Desc {dTip=TExplicit} b = do
    s8 <- checkSize 8 b
    let val = B.toIntegral . B.take s8 $ b
    case val of
        0 -> Nothing
        _ -> checkSize (8*val) b

-- size of Compound
sizeOf Desc {dTip=TCompound, dItems=items} b' = do
    b <- B.checkAligned b'
    (fspec, fspecTotal) <- getFspec b
    -- TODO: check length of items (must be >= length of fspec)
    let subitems :: [(String,Desc)]
        subitems = [(dName dsc,dsc) | (f,dsc) <- zip fspec items, (f==True)]
        offset = length fspecTotal

    dig subitems (B.drop offset b) offset
    where

        dig :: [(String,Desc)] -> B.Bits -> Size -> Maybe Size
        dig [] _ size = Just size
        dig (x:xs) b size = do
            itemSize <- sizeOf (snd x) b
            dig xs (B.drop itemSize b) (itemSize+size)

-- size of unknown
sizeOf _ _ = Nothing

--  | Create datablock
{-
datablock :: Cat -> [Item] -> DataBlock
datablock cat items = DataBlock cat bs where
    bs = c `mappend` ln `mappend` records
    c = B.fromIntegral 8 $ toInteger cat
    ln = B.fromIntegral 16 $ (B.length records `div` 8) + 3
    records = mconcat $ map encode items

encode = undefined
-}

-- | Convert from item to numeric value
toIntegral :: Integral a => Item -> a
toIntegral = B.toIntegral . iBits

-- | Get subitem.
--
-- >    return item >>= child "010" >>= child "SAC"
--
child :: ItemName -> Item -> Maybe Item
child name item = childs item >>= return . lookup name >>= join

-- | Get deep subitem.
--
-- >    childR ["010", "SAC"] item
--
childR :: [ItemName] -> Item -> Maybe Item
childR [] item = Just item
childR (i:is) item = child i item >>= childR is

-- | Get all subitems.
childs :: Item -> Maybe [(ItemName,Maybe Item)]
childs item

    -- Item
    | tip == TItem = do 
        let consume [] _ = Just []
            consume (i:is) b' = do
                (x,y) <- grab i b'
                rest <- consume is y
                Just $ (dName i, Just $ Item i x):rest
        consume items b

    | tip == TExtended = undefined    -- TODO
{-
-- get childs of extended item
childs (Item d@Desc {dTip=TExtended, dLen=Length2 n1 n2, dItems=items} b) = collect items b [] chunks where
    chunks = [n1] ++ repeat n2

    collect items b acc chunks
        | B.null b = acc
        | otherwise = collect items' b2 acc' chunks'
        where
            (b1, b2) = (B.take (n-1) b, B.drop n b)
            (n, chunks') = (head chunks, tail chunks)
            (items',rv) = take b1 items []
            acc' = acc ++ rv
            take b items acc
                | B.null b = (items,reverse acc)
                | otherwise = take (B.drop size b) (tail items) (item:acc)
                where
                    i = head items
                    item = Item i (B.take size b)
                    (Just size) = sizeOf i b
-}

    -- Repetitive
    | tip == TRepetitive = undefined    -- TODO

    -- Compound
    | tip == TCompound = do
        (fspec,fspecTotal) <- getFspec b

        let fspec' = fspec ++ (repeat False)

            consume [] _ = Just []
            consume ((i,f):xs) bs = do
                (item',b') <- fetch f
                rest <- consume xs b'
                Just $ (name,item'):rest
                where
                    name = dName i
                    fetch False = Just (Nothing, bs)
                    fetch True = do
                        (x,y) <- grab i bs
                        Just $ (Just $ Item i x, y)

            checkFspec
                | (length minFspec) <= (length items) = Just minFspec
                | otherwise = Nothing
                where minFspec = reverse . dropWhile (==False) . reverse $ fspec

        _ <- checkFspec
        b' <- B.dropMaybe (length fspecTotal) b
        consume (zip items fspec') b'

    -- unknown
    | otherwise = Nothing
    where
        tip = dTip . iDsc $ item
        items = dItems . iDsc $ item
        b = iBits item

        
{-
-- recreate compound item from subitems
unChilds :: Desc -> [(Name,Maybe Item)] -> Item
unChilds d@Desc {dTip=TCompound, dItems=items} present = assert (length items == length present) $ Item d bs where
    bs = B.pack fspecTotal `mappend` (mconcat . map (encode . fromJust) . filter isJust . map snd $ present)
    fspecTotal
        | fspec == [] = []
        | otherwise = concat leading ++ lastOctet
    leading = map (\l -> l++[True]) (init groups)
    lastOctet = (last groups) ++ [False]
    groups = spl fspec
    spl [] = []
    spl s =
        let (a,b) = splitAt 7 s
        in (fill a):(spl b)
    fill a = take 7 (a++repeat False)
    fspec :: [Bool]
    fspec = strip [isJust . snd $ f | f<-present]
    strip = reverse . dropWhile (==False) . reverse
unChilds _ _ = undefined
-}

