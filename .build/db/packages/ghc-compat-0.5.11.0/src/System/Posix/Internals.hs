-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.Internal.System.Posix.Internals
-- Copyright   :  (c) The University of Glasgow, 1992-2002
-- License     :  see libraries/base/LICENSE
--
-- Maintainer  :  ghc-devs@haskell.org
-- Stability   :  internal
-- Portability :  non-portable (requires POSIX)
--
-- POSIX support layer for the standard libraries.
--
-- /The API of this module is unstable and not meant to be consumed by the general public./
-- If you absolutely must depend on it, make sure to use a tight upper
-- bound, e.g., @base < 4.X@ rather than @base < 5@, because the interface can
-- change rapidly without much warning.
--
-- This library is built on *every* platform, including Win32.
--
-- Non-POSIX compliant in order to support the following features:
--  * S_ISSOCK (no sockets in POSIX)
--
-----------------------------------------------------------------------------

module System.Posix.Internals where
import Control.Concurrent(yield)
import Control.Exception(getMaskingState, MaskingState(..), interruptible)
import Control.Monad
import Data.Bits
import Data.Maybe
import Data.Word
import Foreign.Ptr
import Foreign.C.Error
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Foreign.Storable
import qualified GHC.Foreign as GHC
import GHC.Internal.IO.Device
import System.IO(IOMode(..))
import System.IO.Error
import System.Posix.Types

--import {-# SOURCE #-} GHC.Internal.IO.Encoding (getFileSystemEncoding)
--import qualified GHC.Internal.Foreign.C.String.Encoding as GHC

getFileSystemEncoding = error "getFileSystemEncoding" -- XXX

data {-# CTYPE "struct flock" #-} CFLock
data {-# CTYPE "struct group" #-} CGroup
data {-# CTYPE "struct lconv" #-} CLconv
data {-# CTYPE "struct passwd" #-} CPasswd
data {-# CTYPE "struct sigaction" #-} CSigaction
data {-# CTYPE "sigset_t" #-} CSigset
data {-# CTYPE "struct stat" #-}  CStat
data {-# CTYPE "struct termios" #-} CTermios
data {-# CTYPE "struct tm" #-} CTm
data {-# CTYPE "struct tms" #-} CTms
data {-# CTYPE "struct utimbuf" #-} CUtimbuf
data {-# CTYPE "struct utsname" #-} CUtsname

type FD = CInt

-- ---------------------------------------------------------------------------
-- stat()-related stuff

fdFileSize :: FD -> IO Integer
fdFileSize fd =
  allocaBytes sizeof_stat $ \ p_stat -> do
    throwErrnoIfMinus1Retry_ "fileSize" $
        c_fstat fd p_stat
    c_mode <- st_mode p_stat :: IO CMode
    if not (s_isreg c_mode)
        then return (-1)
        else do
      c_size <- st_size p_stat
      return (fromIntegral c_size)

fileType :: FilePath -> IO IODeviceType
fileType file =
  allocaBytes sizeof_stat $ \ p_stat ->
  withFilePath file $ \p_file -> do
    throwErrnoIfMinus1Retry_ "fileType" $
      c_stat p_file p_stat
    statGetType p_stat

-- NOTE: On Win32 platforms, this will only work with file descriptors
-- referring to file handles. i.e., it'll fail for socket FDs.
fdStat :: FD -> IO (IODeviceType, CDev, CIno)
fdStat fd =
  allocaBytes sizeof_stat $ \ p_stat -> do
    throwErrnoIfMinus1Retry_ "fdType" $
        c_fstat fd p_stat
    ty <- statGetType p_stat
    dev <- st_dev p_stat
    ino <- st_ino p_stat
    return (ty,dev,ino)

fdType :: FD -> IO IODeviceType
fdType fd = do (ty,_,_) <- fdStat fd; return ty

-- | Return a known device type or throw an exception if the device
-- type is unknown.
statGetType :: Ptr CStat -> IO IODeviceType
statGetType p_stat = do
   dev_ty_m <- statGetType_maybe p_stat
   case dev_ty_m of
      Nothing -> ioError ioe_unknownfiletype
      Just dev_ty -> pure dev_ty

-- | Unlike @statGetType@, @statGetType_maybe@ will not throw an exception
-- if the CStat refers to a unknown device type.
--
-- @since base-4.20.1.0
statGetType_maybe :: Ptr CStat -> IO (Maybe IODeviceType)
statGetType_maybe p_stat = do
  c_mode <- st_mode p_stat :: IO CMode
  case () of
      _ | s_isdir c_mode        -> return $ Just Directory
        | s_isfifo c_mode || s_issock c_mode || s_ischr  c_mode
                                -> return $ Just Stream
        | s_isreg c_mode        -> return $ Just RegularFile
         -- Q: map char devices to RawDevice too?
        | s_isblk c_mode        -> return $ Just RawDevice
        | otherwise             -> return Nothing

ioe_unknownfiletype :: IOException
ioe_unknownfiletype = IOError Nothing UnsupportedOperation "fdType"
                        "unknown file type"
                        Nothing
                        Nothing

fdGetMode :: FD -> IO IOMode
fdGetMode fd = do
    flags <- throwErrnoIfMinus1Retry "fdGetMode"
                (c_fcntl_read fd const_f_getfl)
    let
       wH  = (flags .&. o_WRONLY) /= 0
       aH  = (flags .&. o_APPEND) /= 0
       rwH = (flags .&. o_RDWR) /= 0

       mode
         | wH && aH  = AppendMode
         | wH        = WriteMode
         | rwH       = ReadWriteMode
         | otherwise = ReadMode

    return mode

withFilePath :: FilePath -> (CString -> IO a) -> IO a
newFilePath :: FilePath -> IO CString
peekFilePath :: CString -> IO FilePath
peekFilePathLen :: CStringLen -> IO FilePath

withFilePath fp f = do
    enc <- getFileSystemEncoding
    GHC.withCStringLen0 enc fp $ \(str, len) -> do
        checkForInteriorNuls fp (str, len)
        f str
newFilePath fp = do
    enc <- getFileSystemEncoding
    (str, len) <- GHC.newCStringLen0 enc fp
    checkForInteriorNuls fp (str, len)
    return str
peekFilePath fp = getFileSystemEncoding >>= \enc -> GHC.peekCString enc fp
peekFilePathLen fp = getFileSystemEncoding >>= \enc -> GHC.peekCStringLen enc fp

-- | Check an encoded 'FilePath' for internal NUL octets as these are
-- disallowed in POSIX filepaths. See #13660.
checkForInteriorNuls :: FilePath -> CStringLen -> IO ()
checkForInteriorNuls fp (str, len) =
  return ()
{- XXX
    when (len' /= len) (throwInternalNulError fp)
    -- N.B. If the string contains internal NUL codeunits then the strlen will
    -- indicate a size smaller than that returned by withCStringLen.
  where
    len' = case str of Ptr ptr -> I# (cstringLength# ptr)
-}

throwInternalNulError :: FilePath -> IO a
throwInternalNulError fp = ioError err
  where
    err =
      IOError
        { ioe_handle = Nothing
        , ioe_type = InvalidArgument
        , ioe_location = "checkForInteriorNuls"
        , ioe_description = "FilePaths must not contain internal NUL code units."
        , ioe_errno = Nothing
        , ioe_filename = Just fp
        }

-- ---------------------------------------------------------------------------
-- Terminal-related stuff

setEcho :: FD -> Bool -> IO ()
setEcho fd on =
  tcSetAttr fd $ \ p_tios -> do
    lflag <- c_lflag p_tios :: IO CTcflag
    let new_lflag
         | on        = lflag .|. fromIntegral const_echo
         | otherwise = lflag .&. complement (fromIntegral const_echo)
    poke_c_lflag p_tios (new_lflag :: CTcflag)

getEcho :: FD -> IO Bool
getEcho fd =
  tcSetAttr fd $ \ p_tios -> do
    lflag <- c_lflag p_tios :: IO CTcflag
    return ((lflag .&. fromIntegral const_echo) /= 0)

setCooked :: FD -> Bool -> IO ()
setCooked fd cooked =
  tcSetAttr fd $ \ p_tios -> do

    -- turn on/off ICANON
    lflag <- c_lflag p_tios :: IO CTcflag
    let new_lflag | cooked    = lflag .|. (fromIntegral const_icanon)
                  | otherwise = lflag .&. complement (fromIntegral const_icanon)
    poke_c_lflag p_tios (new_lflag :: CTcflag)

    -- set VMIN & VTIME to 1/0 respectively
    when (not cooked) $ do
            c_cc <- ptr_c_cc p_tios
            let vmin  = (c_cc `plusPtr` (fromIntegral const_vmin))  :: Ptr Word8
                vtime = (c_cc `plusPtr` (fromIntegral const_vtime)) :: Ptr Word8
            poke vmin  1
            poke vtime 0

tcSetAttr :: FD -> (Ptr CTermios -> IO a) -> IO a
tcSetAttr fd fun =
     allocaBytes sizeof_termios  $ \p_tios -> do
        throwErrnoIfMinus1Retry_ "tcSetAttr"
           (c_tcgetattr fd p_tios)

        -- Save a copy of termios, if this is a standard file descriptor.
        -- These terminal settings are restored in hs_exit().
        when (fd <= 2) $ do
          p <- get_saved_termios fd
          when (p == nullPtr) $ do
             saved_tios <- mallocBytes sizeof_termios
             copyBytes saved_tios p_tios sizeof_termios
             set_saved_termios fd saved_tios

        -- tcsetattr() when invoked by a background process causes the process
        -- to be sent SIGTTOU regardless of whether the process has TOSTOP set
        -- in its terminal flags (try it...).  This function provides a
        -- wrapper which temporarily blocks SIGTTOU around the call, making it
        -- transparent.
        allocaBytes sizeof_sigset_t $ \ p_sigset ->
          allocaBytes sizeof_sigset_t $ \ p_old_sigset -> do
             throwErrnoIfMinus1_ "sigemptyset" $
                 c_sigemptyset p_sigset
             throwErrnoIfMinus1_ "sigaddset" $
                 c_sigaddset   p_sigset const_sigttou
             throwErrnoIfMinus1_ "sigprocmask" $
                 c_sigprocmask const_sig_block p_sigset p_old_sigset
             r <- fun p_tios  -- do the business
             throwErrnoIfMinus1Retry_ "tcSetAttr" $
                 c_tcsetattr fd const_tcsanow p_tios
             throwErrnoIfMinus1_ "sigprocmask" $
                 c_sigprocmask const_sig_setmask p_old_sigset nullPtr
             return r

get_saved_termios :: CInt -> IO (Ptr CTermios)
get_saved_termios = undefined

set_saved_termios :: CInt -> (Ptr CTermios) -> IO ()
set_saved_termios = undefined

-- ---------------------------------------------------------------------------
-- Turning on non-blocking for a file descriptor

setNonBlockingFD :: FD -> Bool -> IO ()
setNonBlockingFD fd set = do
  flags <- throwErrnoIfMinus1Retry "setNonBlockingFD"
                 (c_fcntl_read fd const_f_getfl)
  let flags' | set       = flags .|. o_NONBLOCK
             | otherwise = flags .&. complement o_NONBLOCK
  when (flags /= flags') $ do
    -- An error when setting O_NONBLOCK isn't fatal: on some systems
    -- there are certain file handles on which this will fail (eg. /dev/null
    -- on FreeBSD) so we throw away the return code from fcntl_write.
    _ <- c_fcntl_write fd const_f_setfl (fromIntegral flags')
    return ()

-- -----------------------------------------------------------------------------
-- Set close-on-exec for a file descriptor

setCloseOnExec :: FD -> IO ()
setCloseOnExec fd =
  throwErrnoIfMinus1_ "setCloseOnExec" $
    c_fcntl_write fd const_f_setfd const_fd_cloexec

-- -----------------------------------------------------------------------------
-- foreign imports

type CFilePath = CString

-- | The same as 'c_safe_open', but an /interruptible operation/
-- as described in "Control.Exception"—it respects `uninterruptibleMask`
-- but not `mask`.
--
-- We want to be able to interrupt an openFile call if
-- it's expensive (NFS, FUSE, etc.), and we especially
-- need to be able to interrupt a blocking open call.
-- See #17912.
--
-- @since base-4.16.0.0
c_interruptible_open :: CFilePath -> CInt -> CMode -> IO CInt
c_interruptible_open filepath oflags mode =
  getMaskingState >>= \case
    -- If we're in an uninterruptible mask, there's basically
    -- no point in using an interruptible FFI call. The open system call
    -- will be interrupted, but the exception won't be delivered
    -- unless the caller manually futzes with the masking state. So
    -- then the caller (assuming they're following the usual conventions)
    -- will retry the call (in response to EINTR), and we've just
    -- wasted everyone's time.
    MaskedUninterruptible -> c_safe_open_ filepath oflags mode
    _ -> do
      open_res <- c_interruptible_open_ filepath oflags mode
      -- c_interruptible_open_ is an interruptible foreign call.
      -- If the call is interrupted by an exception handler
      -- before the system call has returned (so the file is
      -- not yet open), we want to deliver the exception.
      -- In point of fact, we deliver any pending exception
      -- here regardless of the *reason* the system call
      -- fails.
      when (open_res == -1) $
        if hostIsThreaded
          then
            -- GHC.Internal.Control.Exception.allowInterrupt, inlined to avoid
            -- messing with any Haddock links.
            interruptible (pure ())
          else
            -- Try to make this work somewhat better on the non-threaded
            -- RTS. See #8684. This inlines the definition of `yield`; module
            -- dependencies look pretty hairy here and I don't want to make
            -- things worse for one little wrapper.
            interruptible yield
      pure open_res

c_safe_open :: CFilePath -> CInt -> CMode -> IO CInt
c_safe_open filepath oflags mode =
  getMaskingState >>= \case
    -- When exceptions are unmasked, we use an interruptible
    -- open call. If the system call is successfully
    -- interrupted, the situation will be the same as if
    -- the exception had arrived before this function was
    -- called.
    Unmasked -> c_interruptible_open_ filepath oflags mode
    _ -> c_safe_open_ filepath oflags mode

-- | Consult the RTS to find whether it is threaded.
--
-- @since base-4.16.0.0
hostIsThreaded :: Bool
hostIsThreaded = rtsIsThreaded_ /= 0

foreign import ccall unsafe "unistd.h open"
   c_open :: CFilePath -> CInt -> CMode -> IO CInt

-- |
--
-- @since base-4.16.0.0
foreign import ccall interruptible "unistd.h open"
   c_interruptible_open_ :: CFilePath -> CInt -> CMode -> IO CInt

-- |
--
-- @since base-4.16.0.0
rtsIsThreaded_ :: Int
rtsIsThreaded_ = 0

foreign import ccall safe "unistd.h open"
   c_safe_open_ :: CFilePath -> CInt -> CMode -> IO CInt

foreign import ccall unsafe "unistd.h  fstat"
   c_fstat :: CInt -> Ptr CStat -> IO CInt

foreign import ccall unsafe "unistd.h  lstat"
   lstat :: CFilePath -> Ptr CStat -> IO CInt

-- We use CAPI as on some OSs (eg. Linux) this is wrapped by a macro
-- which redirects to the 64-bit-off_t versions when large file
-- support is enabled.

-- See Note [Windows types]
foreign import capi unsafe "unistd.h read"
   c_read :: CInt -> Ptr Word8 -> CSize -> IO CSsize

-- See Note [Windows types]
foreign import capi safe "unistd.h read"
   c_safe_read :: CInt -> Ptr Word8 -> CSize -> IO CSsize

foreign import ccall unsafe "unistd.h umask"
   c_umask :: CMode -> IO CMode

-- See Note [Windows types]
foreign import capi unsafe "unistd.h write"
   c_write :: CInt -> Ptr Word8 -> CSize -> IO CSsize

-- See Note [Windows types]
foreign import capi safe "unistd.h write"
   c_safe_write :: CInt -> Ptr Word8 -> CSize -> IO CSsize

foreign import ccall unsafe "unistd.h pipe"
   c_pipe :: Ptr CInt -> IO CInt

foreign import capi unsafe "unistd.h lseek"
   c_lseek :: CInt -> COff -> CInt -> IO COff

foreign import ccall unsafe "unistd.h access"
   c_access :: CString -> CInt -> IO CInt

foreign import ccall unsafe "unistd.h chmod"
   c_chmod :: CString -> CMode -> IO CInt

foreign import ccall unsafe "unistd.h close"
   c_close :: CInt -> IO CInt

foreign import ccall unsafe "unistd.h creat"
   c_creat :: CString -> CMode -> IO CInt

foreign import ccall unsafe "unistd.h dup"
   c_dup :: CInt -> IO CInt

foreign import ccall unsafe "unistd.h dup2"
   c_dup2 :: CInt -> CInt -> IO CInt

foreign import ccall unsafe "unistd.h isatty"
   c_isatty :: CInt -> IO CInt

foreign import ccall unsafe "unistd.h unlink"
   c_unlink :: CString -> IO CInt

foreign import capi unsafe "unistd.h utime.h utime"
   c_utime :: CString -> Ptr CUtimbuf -> IO CInt

foreign import ccall unsafe "unistd.h getpid"
   c_getpid :: IO CPid

foreign import ccall unsafe "unistd.h stat"
   c_stat :: CFilePath -> Ptr CStat -> IO CInt

foreign import ccall unsafe "unistd.h ftruncate"
   c_ftruncate :: CInt -> COff -> IO CInt

foreign import capi unsafe "unistd.h fcntl"
   c_fcntl_read  :: CInt -> CInt -> IO CInt

foreign import capi unsafe "unistd.h fcntl"
   c_fcntl_write :: CInt -> CInt -> CLong -> IO CInt

foreign import capi unsafe "unistd.h fcntl"
   c_fcntl_lock  :: CInt -> CInt -> Ptr CFLock -> IO CInt

foreign import ccall unsafe "unistd.h fork"
   c_fork :: IO CPid

foreign import ccall unsafe "unistd.h link"
   c_link :: CString -> CString -> IO CInt

-- capi is required at least on Android
foreign import capi unsafe "unistd.h mkfifo"
   c_mkfifo :: CString -> CMode -> IO CInt

foreign import capi unsafe "signal.h value sigemptyset((sigset_t*)$1)"
   c_sigemptyset :: Ptr CSigset -> IO CInt

foreign import capi unsafe "signal.h value sigaddset((sigset_t*)$1, $2)"
   c_sigaddset :: Ptr CSigset -> CInt -> IO CInt

foreign import capi unsafe "signal.h sigprocmask"
   c_sigprocmask :: CInt -> Ptr CSigset -> Ptr CSigset -> IO CInt

-- capi is required at least on Android
foreign import capi unsafe "unistd.h tcgetattr"
   c_tcgetattr :: CInt -> Ptr CTermios -> IO CInt

-- capi is required at least on Android
foreign import capi unsafe "unistd.h tcsetattr"
   c_tcsetattr :: CInt -> CInt -> Ptr CTermios -> IO CInt

foreign import ccall unsafe "unistd.h waitpid"
   c_waitpid :: CPid -> Ptr CInt -> CInt -> IO CPid

-- POSIX flags only:
foreign import ccall unsafe "unistd.h value O_RDONLY" o_RDONLY :: CInt
foreign import ccall unsafe "unistd.h value O_WRONLY" o_WRONLY :: CInt
foreign import ccall unsafe "unistd.h value O_RDWR"   o_RDWR   :: CInt
foreign import ccall unsafe "unistd.h value O_APPEND" o_APPEND :: CInt
foreign import ccall unsafe "unistd.h value O_CREAT"  o_CREAT  :: CInt
foreign import ccall unsafe "unistd.h value O_EXCL"   o_EXCL   :: CInt
foreign import ccall unsafe "unistd.h value O_TRUNC"  o_TRUNC  :: CInt

-- non-POSIX flags.
foreign import ccall unsafe "unistd.h value O_NOCTTY"   o_NOCTTY   :: CInt
foreign import ccall unsafe "unistd.h value O_NONBLOCK" o_NONBLOCK :: CInt
--foreign import ccall unsafe "unistd.h fcntl.h value O_BINARY"   o_BINARY   :: CInt

foreign import capi unsafe "sys/stat.h S_ISREG"  c_s_isreg  :: CMode -> CInt
foreign import capi unsafe "sys/stat.h S_ISCHR"  c_s_ischr  :: CMode -> CInt
foreign import capi unsafe "sys/stat.h S_ISBLK"  c_s_isblk  :: CMode -> CInt
foreign import capi unsafe "sys/stat.h S_ISDIR"  c_s_isdir  :: CMode -> CInt
foreign import capi unsafe "sys/stat.h S_ISFIFO" c_s_isfifo :: CMode -> CInt

s_isreg  :: CMode -> Bool
s_isreg cm = c_s_isreg cm /= 0
s_ischr  :: CMode -> Bool
s_ischr cm = c_s_ischr cm /= 0
s_isblk  :: CMode -> Bool
s_isblk cm = c_s_isblk cm /= 0
s_isdir  :: CMode -> Bool
s_isdir cm = c_s_isdir cm /= 0
s_isfifo :: CMode -> Bool
s_isfifo cm = c_s_isfifo cm /= 0

foreign import capi  unsafe "unistd.h value sizeof(struct stat)" sizeof_stat :: Int

foreign import ccall unsafe "unistd.h value ((struct stat*)$1)->st_mtime" st_mtime :: Ptr CStat -> IO CTime
foreign import ccall unsafe "unistd.h value ((struct stat*)$1)->st_size" st_size :: Ptr CStat -> IO COff
foreign import ccall unsafe "unistd.h value ((struct stat*)$1)->st_mode" st_mode :: Ptr CStat -> IO CMode
foreign import ccall unsafe "unistd.h value ((struct stat*)$1)->st_dev" st_dev :: Ptr CStat -> IO CDev
foreign import ccall unsafe "unistd.h value ((struct stat*)$1)->st_ino" st_ino :: Ptr CStat -> IO CIno

foreign import ccall unsafe "unistd.h value ECHO"         const_echo :: CInt
foreign import ccall unsafe "unistd.h value TCSANOW"      const_tcsanow :: CInt
foreign import ccall unsafe "unistd.h value ICANON"       const_icanon :: CInt
foreign import ccall unsafe "unistd.h value VMIN"         const_vmin   :: CInt
foreign import ccall unsafe "unistd.h value VTIME"        const_vtime  :: CInt
foreign import ccall unsafe "unistd.h value SIGTTOU"      const_sigttou :: CInt
foreign import ccall unsafe "unistd.h value SIG_BLOCK"    const_sig_block :: CInt
foreign import ccall unsafe "unistd.h value SIG_SETMASK"  const_sig_setmask :: CInt
foreign import ccall unsafe "unistd.h value F_GETFL"      const_f_getfl :: CInt
foreign import ccall unsafe "unistd.h value F_SETFL"      const_f_setfl :: CInt
foreign import ccall unsafe "unistd.h value F_SETFD"      const_f_setfd :: CInt
foreign import ccall unsafe "unistd.h value FD_CLOEXEC"   const_fd_cloexec :: CLong

foreign import capi  unsafe "unistd.h value sizeof(struct termios)"  sizeof_termios :: Int
foreign import capi  unsafe "unistd.h value sizeof(sigset_t)" sizeof_sigset_t :: Int

foreign import ccall unsafe "unistd.h termios.h value ((struct termios*)$1)->c_lflag" c_lflag :: Ptr CTermios -> IO CTcflag
foreign import ccall unsafe "unistd.h termios.h value ((struct termios*)$1)->c_lflag = $2" poke_c_lflag :: Ptr CTermios -> CTcflag -> IO ()
foreign import ccall unsafe "unistd.h value &((struct termios*)$1)->c_cc" ptr_c_cc  :: Ptr CTermios -> IO (Ptr Word8)

s_issock :: CMode -> Bool
s_issock cmode = c_s_issock cmode /= 0
foreign import capi unsafe "sys/stat.h S_ISSOCK" c_s_issock :: CMode -> CInt

foreign import capi  unsafe "stdio.h value BUFSIZ"  dEFAULT_BUFFER_SIZE :: Int
foreign import capi  unsafe "stdio.h value SEEK_CUR" sEEK_CUR :: CInt
foreign import capi  unsafe "stdio.h value SEEK_SET" sEEK_SET :: CInt
foreign import capi  unsafe "stdio.h value SEEK_END" sEEK_END :: CInt
