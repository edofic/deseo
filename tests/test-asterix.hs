{-# LANGUAGE CPP #-}

module Main where

import Control.Monad
import qualified Data.Map as Map
import Data.Maybe
import Data.Either

import System.FilePath

import Test.Framework (defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.QuickCheck
import Test.HUnit

import Data.Asterix as A
import qualified Data.BitString as B

xmldir = (</> "xml") $ dropFileName __FILE__

main = defaultMain tests

tests = [
        testGroup "read xml" [
            testCase "good" readGood
            , testCase "bad" readBad
        ], 
        testGroup "datablocks" [
            testCase "decode" dbdecode
            , testCase "encode" dbencode
        ],
        testGroup "records" [
            testCase "decode" splitRec
            , testCase "childs" childs'
        ],
        testGroup "create" [
            testCase "create" testCreate
            , testCase "limits" testLimits
        ],
        testGroup "convert" [
            testCase "get1" testGet1
            , testCase "get2a" testGet2a
            , testCase "get2b" testGet2b
            , testCase "set1" testSet1
        ],
        testGroup "util" [
            testCase "sizeof" testSizeOf
        ],
        testGroup "types" [
            testCase "extended" testExtended
        ],
        testGroup "types" [
            testCase "extended variant" testExtendedVariant
        ]
    ]

assertLeft x = case x of
    Left e -> return ()
    Right val -> assertFailure $ "unexpected value " ++ (show val)

assertRight x = case x of
    Left e -> assertFailure e
    _ -> return ()

readGood :: Assertion
readGood = do
    cat' <- readFile (xmldir </> "cat000_0.0.xml") >>= return . categoryDescription
    assertRight $ do
        cat <- cat'

        -- TODO: check content

        Right "OK"
    
readBad :: Assertion
readBad = do
    let c = categoryDescription "some invalid xml string"
    assertLeft c

dbdecode :: Assertion
dbdecode = do
    let x0 = B.pack []
        x1 = B.fromXIntegral (8*11) 0x02000bf0931702b847147e
        x2 = B.fromXIntegral (8*10) 0x01000501020200050304

    assertEqual "0 datablocks" (Just []) (toDataBlocks x0)

    assertEqual "1 datablock"
        (Just [DataBlock {dbCat=2, dbData=(B.drop 24 x1)}])
        (toDataBlocks x1)

    assertEqual "2 datablocks"
        (Just [
            DataBlock {dbCat=1, dbData=(B.fromXIntegral 16 0x0102)}
            , DataBlock {dbCat=2, dbData=(B.fromXIntegral 16 0x0304)}
            ])
        (toDataBlocks x2)

dbencode :: Assertion
dbencode = do
    return ()

splitRec :: Assertion
splitRec = do
    cat0 <- readFile (xmldir </> "cat000_0.0.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        parse db = return db 
                >>= toDataBlocks 
                >>= mapM (toRecords profiles)
                >>= return . join
                >>= return . map iBits

        d0 = B.fromXIntegral 32 0x000003
        d1a = B.fromXIntegral 32 0x00000400
        d1b = B.fromXIntegral 48 0x000006800203
        d2 = B.fromXIntegral 72 0x000009800203800405

    assertEqual "0 rec" Nothing (parse d0)
    assertEqual "1a rec" (Just [B.fromXIntegral 8 0]) (parse d1a)
    assertEqual "1b rec" (Just [B.fromXIntegral 24 0x800203]) (parse d1b)
    assertEqual "2 rec" (Just [B.fromXIntegral 24 0x800203, B.fromXIntegral 24 0x800405]) (parse d2)

childs' :: Assertion
childs' = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        parse db = return db 
                >>= toDataBlocks 
                >>= mapM (toRecords profiles)
                >>= return . join

        d = B.fromXIntegral 48 0x000006800203
        Just rr = parse d
        r = head rr
        Just (i010:i020:_) = childs r
        Just i010' = snd i010
        Just (sac:sic:_) = childs i010'

        realSac = B.fromXIntegral 8 0x02
        realSic = B.fromXIntegral 8 0x03

    assertEqual "i010" ("010",True) (fst i010, isJust . snd $ i010)
    assertEqual "i020" ("020",False) (fst i020, isJust . snd $ i020)

    assertEqual "sac" "SAC" (fst sac)
    assertEqual "sic" "SIC" (fst sic)

    assertEqual "sac" realSac (iBits . fromJust . snd $ sac)
    assertEqual "sic" realSic (iBits . fromJust . snd $ sic)

    assertEqual "sac" (Just realSac) (childR ["010", "SAC"] r >>= return . iBits)
    assertEqual "sic" (Just realSic) (childR ["010", "SIC"] r >>= return . iBits)
    assertEqual "sec" Nothing (childR ["010", "SEC"] r >>= return . iBits)

    assertEqual "childs/unchilds" (Just r) (childs r >>= unChilds (iDsc r))

testCreate :: Assertion
testCreate = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        
        rec0 = create cat0'' $ return ()

        rec1a = create cat0'' $ do
                    putItem "010" $ fromBits (B.fromXIntegral 16 0x0102)

        rec1b = create cat0'' $ do
                    putItem "010" $ fromRaw 0x0102

        rec1c = create cat0'' $ do
                    putItem "010" $ fromValues fromRaw [("SAC", 0x01), ("SIC", 0x02)]

        rec1d = create cat0'' $ do
                    "010" <! fromRaw 0x0102

        rec1e = create cat0'' $ do
                    "010" `putItem` fromRaw 0x0102

        rec2 = fromValues fromRaw [("010", 0x0102)] cat0''

    assertEqual "created 0" True (isJust rec0)
    assertEqual "created 1a" True (isJust rec1a)

    assertEqual "not equal" False (rec0==rec1a)
    assertEqual "equal 1b" rec1a rec1b
    assertEqual "equal 1c" rec1a rec1c
    assertEqual "equal 1d" rec1a rec1d
    assertEqual "equal 1e" rec1a rec1e
    assertEqual "equal 2" rec1a rec2

        {-

        rec2 = create cat0 $ do
                    putItem "006" $ fromList [
                                        [("ModeS", 0x010203)]
                                        , [("ModeS", 0x020304)]
        rec3 = create cat0 $ do
                    putItem "007" fromSpare
        -}

testGet1 :: Assertion
testGet1 = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        
        rec = create cat0'' $ do
            "010" <! fromValues fromRaw [("SAC", 0x01), ("SIC", 0x02)]
            "030" <! fromRaw 256
            "031" <! fromValues fromRaw [("X", 0x01), ("Y", 0x02)]

        Just i030 = rec >>= child "030" >>= toNatural

    assertEqual "double" 2.0 i030
    assertEqual "double" (i030 == 2.0) True
    assertEqual "double" (2.0 == i030) True
    assertEqual "double" (i030 > 1.9) True
    assertEqual "double" (1.9 < i030) True
    assertEqual "double" (i030 >= 1.9) True
    assertEqual "double" (i030 < 2.1) True
    assertEqual "double" (i030 <= 2.1) True
    assertEqual "double" (i030 /= 0) True
    assertEqual "double" (i030 /= 0.0) True

testGet2a :: Assertion
testGet2a = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        ae = assertEqual
        
        rec = create cat0'' $ do
            "030" <! fromRaw 256
            "031" <! fromValues fromRaw [("X", 0x01), ("Y", 0x02)]
            "041" <! fromValues fromRaw [("X", 0x01), ("Y", 0x02)]
            "042" <! fromValues fromRaw [("X", 0x01), ("Y", 0x02)]

        Just i030 = rec >>= child "030" >>= toNatural
        Just i031x = rec >>= childR ["031","X"] >>= toNatural
        Just i031y = rec >>= childR ["031","Y"] >>= toNatural
        Just i041x = rec >>= childR ["041","X"] >>= toNatural
        Just i042x = rec >>= childR ["042","X"] >>= toNatural

    ae "030" (EDouble 2) i030
    ae "031x" (EDouble 0.5) i031x
    ae "031y" (EDouble 1.0) i031y
    ae "i041x" (EInteger 1) i041x
    ae "i042x" (EInteger 1) i042x

testGet2b :: Assertion
testGet2b = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        ae = assertEqual
        
        rec = create cat0'' $ do
            "030" <! fromRaw 0xFFFFFF
            "031" <! fromValues fromRaw [("X", 0xFFFFFF), ("Y", 0xFFFFFF)]
            "041" <! fromValues fromRaw [("X", 0xFF), ("Y", 0xFF)]
            "042" <! fromValues fromRaw [("X", 0xFF), ("Y", 0xFF)]

        Just i030 = rec >>= child "030" >>= toNatural
        Just i031x = rec >>= childR ["031","X"] >>= toNatural
        Just i031y = rec >>= childR ["031","Y"] >>= toNatural
        Just i041x = rec >>= childR ["041","X"] >>= toNatural
        Just i042x = rec >>= childR ["042","X"] >>= toNatural

    ae "030" (EDouble (0xffffff/128)) i030
    ae "031x" (EDouble (-0.5)) i031x
    ae "031y" (EDouble (-0.5)) i031y
    ae "i041x" (EInteger (-1)) i041x
    ae "i042x" (EInteger 255) i042x

testSet1 :: Assertion
testSet1 = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        ae = assertEqual
        
        rec = create cat0'' $ do
            "030" <! fromRaw (-1)
            "031" <! fromValues fromNatural [("X", 2), ("Y", (-2))]
            "041" <! fromValues fromNatural [("X", (-3)), ("Y", 4)]
            "042" <! fromValues fromNatural [("X", 255), ("Y", 6)]

        Just i030 = rec >>= child "030" >>= toNatural
        Just i031x = rec >>= childR ["031","X"] >>= toNatural
        Just i031y = rec >>= childR ["031","Y"] >>= toNatural
        Just i041x = rec >>= childR ["041","X"] >>= toNatural
        Just i042x = rec >>= childR ["042","X"] >>= toNatural

    ae "030" (EDouble (0xffffff/128)) i030
    ae "031x" (EDouble (2)) i031x
    ae "031y" (EDouble (-2)) i031y
    ae "i041x" (EInteger (-3)) i041x
    ae "i042x" (EInteger 255) i042x

testSizeOf :: Assertion
testSizeOf = do
    
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"

    assertEqual "empty" (Just 0) (sizeOf cat0'' (B.pack []))

testLimits :: Assertion
testLimits = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        
        rec1 = create cat0'' $ do
            "031" <! fromValues fromNatural [("X", 100), ("Y", (-100))]

        rec2a = create cat0'' $ do
            "031" <! fromValues fromNatural [("X", 100.1), ("Y", (-100))]

        rec2b = create cat0'' $ do
            "031" <! fromValues fromNatural [("X", 100), ("Y", (-100.1))]

        rec3a = create cat0'' $ do
            "031" <! fromValues fromRaw [("X", 200), ("Y", (-500))]

        rec3b = create cat0'' $ do
            "031" <! fromValues fromRaw [("X", 500), ("Y", (-200))]

    assertEqual "valid" True (isJust $ rec1 >>= childR ["031","X"] >>= toNatural)
    assertEqual "invalidx" True (isNothing $ rec2a >>= childR ["031","X"] >>= toNatural)
    assertEqual "invalidy" True (isNothing $ rec2b >>= childR ["031","X"] >>= toNatural)

    assertEqual "valid" (Just 100) (rec3a >>= childR ["031","X"] >>= toNatural)
    assertEqual "invalidy" Nothing (rec3a >>= childR ["031","Y"] >>= toNatural)
    assertEqual "invalidx" Nothing (rec3b >>= childR ["031","X"] >>= toNatural)
    assertEqual "valid" (Just (-100)) (rec3b >>= childR ["031","Y"] >>= toNatural)

testExtended :: Assertion
testExtended = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        
        rec1 = create cat0'' $ "050" <! fromValues fromRaw [("X", 1)]
        rec2 = create cat0'' $ "050" <! fromValues fromRaw [("X", 1),("Y", 2)]
        rec3 = create cat0'' $ "050" <! fromValues fromRaw [("X", 1),("Y", 2),("A",3)]
        rec4 = create cat0'' $ "050" <! fromValues fromRaw [("X", 1),("Y", 2),("A",3),("B",4)]
        rec5 = create cat0'' $ "050" <! fromValues fromRaw [("X", 1),("Y", 2),("A",3),("B",4),("C",5)]

        Just c2 = rec2 >>= child "050" >>= childs
        Just c5 = rec5 >>= child "050" >>= childs

    assertEqual "X"     False   (isJust rec1)
    assertEqual "XY"    True    (isJust rec2)
    assertEqual "XYA"   True    (isJust rec3)
    assertEqual "XYAB"  False   (isJust rec4)
    assertEqual "XYABC" True    (isJust rec5)

    assertEqual "len2"  5   (length c2)
    assertEqual "len5"  5   (length c5)

    assertEqual "X" Nothing     (rec1 >>= childR ["050","X"] >>= toRaw)
    assertEqual "X" (Just 1)    (rec2 >>= childR ["050","X"] >>= toRaw)
    assertEqual "X" (Just 1)    (rec3 >>= childR ["050","X"] >>= toRaw)
    assertEqual "X" Nothing     (rec4 >>= childR ["050","X"] >>= toRaw)
    assertEqual "X" (Just 1)    (rec5 >>= childR ["050","X"] >>= toRaw)

    assertEqual "Y" Nothing     (rec1 >>= childR ["050","Y"] >>= toRaw)
    assertEqual "Y" (Just 2)    (rec2 >>= childR ["050","Y"] >>= toRaw)
    assertEqual "Y" (Just 2)    (rec3 >>= childR ["050","Y"] >>= toRaw)
    assertEqual "Y" Nothing     (rec4 >>= childR ["050","Y"] >>= toRaw)
    assertEqual "Y" (Just 2)    (rec5 >>= childR ["050","Y"] >>= toRaw)

    assertEqual "A" Nothing     (rec1 >>= childR ["050","A"] >>= toRaw)
    assertEqual "A" Nothing     (rec2 >>= childR ["050","A"] >>= toRaw)
    assertEqual "A" (Just 3)    (rec3 >>= childR ["050","A"] >>= toRaw)
    assertEqual "A" Nothing     (rec4 >>= childR ["050","A"] >>= toRaw)
    assertEqual "A" (Just 3)    (rec5 >>= childR ["050","A"] >>= toRaw)

    assertEqual "B" Nothing     (rec1 >>= childR ["050","B"] >>= toRaw)
    assertEqual "B" Nothing     (rec2 >>= childR ["050","B"] >>= toRaw)
    assertEqual "B" Nothing     (rec3 >>= childR ["050","B"] >>= toRaw)
    assertEqual "B" Nothing     (rec4 >>= childR ["050","B"] >>= toRaw)
    assertEqual "B" (Just 4)    (rec5 >>= childR ["050","B"] >>= toRaw)

    assertEqual "C" Nothing     (rec1 >>= childR ["050","C"] >>= toRaw)
    assertEqual "C" Nothing     (rec2 >>= childR ["050","C"] >>= toRaw)
    assertEqual "C" Nothing     (rec3 >>= childR ["050","C"] >>= toRaw)
    assertEqual "C" Nothing     (rec4 >>= childR ["050","C"] >>= toRaw)
    assertEqual "C" (Just 5)    (rec5 >>= childR ["050","C"] >>= toRaw)

testExtendedVariant :: Assertion
testExtendedVariant = do
    cat0 <- readFile (xmldir </> "cat000_1.2.xml") >>= return . categoryDescription
    let profiles = Map.fromList [(cCat c, c) | c<-(rights [cat0])]
        (Right cat0') = cat0
        (Just cat0'') = uapByName cat0' "uap"
        
        rec1 = create cat0'' $ "051" <! fromValues fromRaw [("A", 1)]
        rec2 = create cat0'' $ "051" <! fromValues fromRaw [("A", 1),("B", 2)]
        rec3 = create cat0'' $ "051" <! fromValues fromRaw [("A", 1),("B", 2),("C",3)]

        Just c2 = rec2 >>= child "051" >>= childs

    assertEqual "A"     False   (isJust rec1)
    assertEqual "AB"    True    (isJust rec2)
    assertEqual "ABC"   True    (isJust rec3)

    assertEqual "len2"  2   (length c2)

    assertEqual "A" Nothing     (rec1 >>= childR ["051","A"] >>= toRaw)
    assertEqual "A" (Just 1)    (rec2 >>= childR ["051","A"] >>= toRaw)
    assertEqual "A" (Just 1)    (rec3 >>= childR ["051","A"] >>= toRaw)

    assertEqual "B" Nothing     (rec1 >>= childR ["051","B"] >>= toRaw)
    assertEqual "B" (Just 2)    (rec2 >>= childR ["051","B"] >>= toRaw)
    assertEqual "B" (Just 2)    (rec3 >>= childR ["051","B"] >>= toRaw)

    assertEqual "C" Nothing     (rec1 >>= childR ["051","C"] >>= toRaw)
    assertEqual "C" Nothing     (rec2 >>= childR ["051","C"] >>= toRaw)
    assertEqual "C" (Just 3)    (rec3 >>= childR ["051","C"] >>= toRaw)

