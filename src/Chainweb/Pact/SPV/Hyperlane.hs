{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Chainweb.Pact.SPV.Hyperlane where

import Control.Error
import Control.Lens hiding (index)
import Control.Monad.Catch
import Control.Monad.Except

import Data.DoubleWord
import Data.Decimal
import Data.Ratio
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as Builder
import Data.Default (def)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Short as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Binary as Binary
import qualified Data.Binary.Put as Binary
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as V

import qualified Crypto.Secp256k1 as ECDSA

import Ethereum.Misc hiding (Word256)

import Pact.Types.Runtime

import Chainweb.Pact.SPV.Hyperlane.Binary

-- | Parses the object and evaluates Hyperlane command
evalHyperlaneCommand :: Object Name -> ExceptT Text IO (Object Name)
evalHyperlaneCommand (_objectMap . _oObject -> om) = do
  case (M.lookup "storageLocation" om, M.lookup "signature" om) of
    (Just (TLitString storageLocation), Just (TLitString sig)) -> recoverAddressValidatorAnnouncement storageLocation sig
    _ -> case (M.lookup "message" om, M.lookup "metadata" om, M.lookup "validators" om, M.lookup "threshold" om) of
      (Just (TLitString message), Just (TLitString metadata), Just (TList validators _ _), Just (TLitInteger threshold)) ->
        let
          convert (TLitString v) = Just v
          convert _ = Nothing
        in verifySignatures message metadata (V.mapMaybe convert validators) (fromInteger threshold)

      (Just (TObject o _), _, _, _) -> encodeHyperMessage o
      _ -> throwError "Unknown hyperlane command"

-- | Decodes Hyperlane binary message and metadata,
-- verifies against the provided signatures using the provided threshold.
--
-- Requires that m-of-n validators verify a merkle root, and verifies a me∑rkle proof of message against that root.
--
-- The original algorithm in hyperlane.
-- https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/v3/solidity/contracts/isms/multisig/AbstractMultisigIsm.sol#L67
verifySignatures :: Text -> Text -> V.Vector Text -> Int -> ExceptT Text IO (Object Name)
verifySignatures hexMessage hexMetadata validators threshold = do
  message <- case decodeHex hexMessage of
          Right s -> pure s
          Left e -> throwError $ Text.pack $ "Decoding of HyperlaneMessage failed: " ++ e

  let HyperlaneMessage{..} = Binary.decode $ BL.fromStrict $ message

  metadata <- case BL.fromStrict <$> decodeHex hexMetadata of
          Right s -> pure s
          Left e -> throwError $ Text.pack $ "Decoding of Metadata failed: " ++ e

  let MessageIdMultisigIsmMetadata{..} = Binary.decode metadata

  let
    domainHash = getKeccak256Hash $ BL.toStrict $ Binary.runPut $ do
      -- Corresponds to abi.encodePacked behaviour
      Binary.put hmOriginDomain
      putBS mmimOriginMerkleTreeAddress
      putBS "HYPERLANE"

  let messageId = getKeccak256Hash message

  let
    hash' = getKeccak256Hash $ BL.toStrict $ Binary.runPut $ do
      -- Corresponds to abi.encodePacked behaviour
      putBS domainHash
      putBS mmimSignedCheckpointRoot
      Binary.put mmimSignedCheckpointIndex
      putBS messageId
  let
    digest = keccak256 $ BL.toStrict $ Binary.runPut $ do
      -- Corresponds to abi.encodePacked behaviour
      putBS ethereumHeader
      putBS hash'

  addresses <- mapM (recoverHexAddress digest) mmimSignatures

  let verificationAddresses = take threshold $ catMaybes addresses
  let verifyStep (_, vals) signer = case V.elemIndex signer vals of
        Just i -> let newV = snd $ V.splitAt (i + 1) vals in (True, newV)
        Nothing -> (False, V.empty)
  let verified = fst $ foldl verifyStep (False, validators) verificationAddresses

  let TokenMessageERC20{..} = hmTokenMessage
  let
    encodedSender = encodeHex hmSender
    encodedRecipient = encodeHex hmRecipient
    hmObj = obj
          [ ("version", tLit $ LInteger $ toInteger hmVersion)
          , ("nonce", tLit $ LInteger $ toInteger hmNonce)
          , ("originDomain", tLit $ LInteger $ toInteger hmOriginDomain)
          , ("sender", tStr $ asString encodedSender)
          , ("destinationDomain", tLit $ LInteger $ toInteger hmDestinationDomain)
          , ("recipient", tStr $ asString encodedRecipient)
          , ("tokenMessage", obj
              ([ ("recipient", tStr $ asString tmRecipient)
               , ("amount", tLit $ LDecimal $ wordToDecimal tmAmount)
              ])
            )
          ]
  pure $ mkObject [ ("message", hmObj), ("messageId", tStr $ asString $ encodeHex messageId), ("verified", tLit $ LBool verified) ]

-- | Recovers address from provided signature using the calculated digest with provided storageLocation.
recoverAddressValidatorAnnouncement :: Text -> Text -> ExceptT Text IO (Object Name)
recoverAddressValidatorAnnouncement storageLocation sig = do
  signatureBinary <- case decodeHex sig of
          Right s -> pure s
          Left e -> throwError $ Text.pack $ "Decoding of signature failed: " ++ e
  domainHash <- case decodeHex domainHashHex of
          Right s -> pure s
          Left e -> throwError $ Text.pack $ "Decoding of domainHashHex failed: " ++ e

  let
    hash' = getKeccak256Hash $ BL.toStrict $ Binary.runPut $ do
      -- Corresponds to abi.encodePacked behaviour
      putBS domainHash
      putBS $ Text.encodeUtf8 storageLocation

  let
    announcementDigest = keccak256 $ BL.toStrict $ Binary.runPut $ do
      -- Corresponds to abi.encodePacked behaviour
      putBS ethereumHeader
      putBS hash'

  address <- recoverHexAddress announcementDigest signatureBinary
  let addr = fmap (tStr . asString) $ address

  case addr of
    Just a -> return $ mkObject [ ("address", a) ]
    Nothing -> throwError "Failed to recover address"

-- | Encodes pact object into Hyperlane binary message
encodeHyperMessage :: Object Name -> ExceptT Text IO (Object Name)
encodeHyperMessage o = do
  let
    om = _objectMap $ _oObject o
    tokenMessage = om ^? at "tokenMessage" . _Just . _TObject . _1

  hmTokenMessage <- case parseTokenMessageERC20 <$> tokenMessage of
    Just (Just t) -> pure t
    _ -> throwError "Couldn't encode TokenMessageERC20"

  let
    newObj = do
      hmVersion <- om ^? at "version" . _Just . _TLiteral . _1 . _LInteger . to fromIntegral
      hmNonce <- om ^? at "nonce" . _Just . _TLiteral . _1 . _LInteger . to fromIntegral
      hmOriginDomain <- om ^? at "originDomain" . _Just . _TLiteral . _1 . _LInteger . to fromIntegral
      hmSender <- om ^? at "sender" . _Just . _TLiteral . _1 . _LString . to decodeHex . _Right
      hmDestinationDomain <- om ^? at "destinationDomain" . _Just . _TLiteral . _1 . _LInteger . to fromIntegral
      hmRecipient <- om ^? at "recipient" . _Just . _TLiteral . _1 . _LString . to decodeHex . _Right

      let hm = HyperlaneMessage{..}
      let b = BL.toStrict $ Binary.encode hm
      let messageId = encodeHex $ getKeccak256Hash b
      let hex = encodeHex b
      pure $ mkObject [ ("encodedMessage", tStr $ asString hex), ("messageId", tStr $ asString messageId) ]
  case newObj of
    Just o' -> pure o'
    _ -> throwError "Couldn't encode HyperlaneMessage"

-- | Parses 'TokenMessageERC20' from provided pact object.
parseTokenMessageERC20 :: Object Name -> Maybe TokenMessageERC20
parseTokenMessageERC20 o = do
  let om = _objectMap $ _oObject o
  tmRecipient <- om ^? at "recipient" . _Just . _TLiteral . _1 . _LString
  tmAmount <- om ^? at "amount" . _Just . _TLiteral . _1 . _LDecimal . to decimalToWord
  pure $ TokenMessageERC20{..}

encodeTokenMessageERC20 :: Object Name -> Maybe Text
encodeTokenMessageERC20 o = do
  tm <- parseTokenMessageERC20 o
  let hex = encodeHex $ BL.toStrict $ Binary.encode tm
  pure hex

-- | Recovers the address from keccak256 encoded digest and signature.
recoverHexAddress :: MonadThrow m => Keccak256Hash -> B.ByteString -> m (Maybe Text)
recoverHexAddress digest sig' = do
  fnDigest <- ECDSA.ecdsaMessageDigest $ _getBytesN $ _getKeccak256Hash digest
  let
    mkR s = ECDSA.ecdsaR $ BS.toShort s
    mkS s = ECDSA.ecdsaS $ BS.toShort s
    recoverAddress sig = do
      let (begin, end) = B.splitAt 32 sig
      r <- mkR begin
      s <- mkS (B.take 32 end)
      pure $ ECDSA.ecdsaRecoverPublicKey fnDigest r s False False <&> getAddress

  addr <- recoverAddress sig'
  pure $ encodeHex <$> addr

-- | Returns an address, a rightmost 160 bits of the keccak hash of the public key.
getAddress :: ECDSA.EcdsaPublicKey -> B.ByteString
getAddress pubkey = B.drop 12 $ getKeccak256Hash $ BS.fromShort $ ECDSA.ecdsaPublicKeyBytes pubkey

-- | This is a kadena's domain hash calculated in Solidity as
-- keccak256(abi.encodePacked(626, "kb-mailbox", "HYPERLANE_ANNOUNCEMENT"))
domainHashHex :: Text
domainHashHex = "0xa69e6ef1a8e62aa6b513bd7d694c6d237164fb04df4e5fb4106e47bf5b5a0428"

encodeHex :: B.ByteString -> Text
encodeHex = ((<>) "0x") . Text.decodeUtf8 . B.toStrict . Builder.toLazyByteString . Builder.byteStringHex

decodeHex :: Text -> Either String B.ByteString
decodeHex s = B16.decode $ Text.encodeUtf8 $ Text.drop 2 s

ethereumHeader :: B.ByteString
ethereumHeader = "\x19Ethereum Signed Message:\n32"

decimalToWord :: Decimal -> Word256
decimalToWord d =
  let ethInWei = 1000000000000000000 -- 1e18
  in round $ d * ethInWei

wordToDecimal :: Word256 -> Decimal
wordToDecimal w =
  let i = toInteger w
      ethInWei = 1000000000000000000 -- 1e18
      (d, m) = i `divMod` ethInWei
  in fromInteger d + fromRational (m % ethInWei)

getKeccak256Hash :: B.ByteString -> B.ByteString
getKeccak256Hash = BS.fromShort . _getBytesN . _getKeccak256Hash . keccak256

mkObject :: [(FieldKey, Term n)] -> Object n
mkObject ps = Object (ObjectMap (M.fromList ps)) TyAny Nothing def

obj :: [(FieldKey, Term n)] -> Term n
obj = toTObject TyAny def
