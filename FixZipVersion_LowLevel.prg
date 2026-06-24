*===============================================================================
*  FixZipVersion_LowLevel.prg                                Visual FoxPro 9
*-------------------------------------------------------------------------------
*  Author : Bernhard Reiter / crossVault GmbH
*  Purpose: Make ZIP archives created by modern producers (e.g. .NET
*           System.IO.Compression) extractable by Craig Boyd's
*           vfpcompression.fll (UnzipQuick).
*
*  Background:
*     vfpcompression.fll rejects any archive entry whose
*     "version needed to extract" field is greater than 10 (ZIP spec 1.0).
*     .NET writes the spec-correct value 20 (2.0) for Deflate entries, which
*     the old FLL refuses. (jszip happened to write 10, so Node.js output
*     worked.) This tool rewrites the field back to 10.
*
*  How it works:
*     Pure low-level / in-place. Only the End-Of-Central-Directory record and
*     the Central Directory block are read; only the 2-byte "version-needed"
*     fields in the Local and Central headers are overwritten via FSEEK+FWRITE.
*     The compressed payload is never read or rewritten -> minimal I/O, no full
*     file rewrite, no in-memory string copies.
*
*  Call as a procedure (shows a message box):
*     DO FixZipVersion_LowLevel WITH "c:\temp\file.zip"
*
*  Call as a function (silent, for production use):
*     lnRes = FixZipVersionLL("c:\temp\file.zip", 10)
*     *  >= 0  number of header fields corrected
*     *  -1    error (file missing, unreadable, ZIP64, or write failure)
*
*  (c) crossVault GmbH. Provided as-is, without warranty.
*===============================================================================
LPARAMETERS tcZipFile, tnTargetVersion

IF VARTYPE(tnTargetVersion) <> "N"
   tnTargetVersion = 10
ENDIF

LOCAL lnChanged
lnChanged = FixZipVersionLL(tcZipFile, tnTargetVersion)

DO CASE
CASE lnChanged < 0
   MESSAGEBOX("Could not process the ZIP file:" + CHR(13) + ;
              TRANSFORM(tcZipFile), 16, "ZIP Fix")
CASE lnChanged = 0
   MESSAGEBOX("Already fine - no change needed.", 64, "ZIP Fix")
OTHERWISE
   MESSAGEBOX(TRANSFORM(lnChanged) + " header field(s) corrected.", 64, "ZIP Fix")
ENDCASE

RETURN lnChanged


*-------------------------------------------------------------------------------
FUNCTION FixZipVersionLL(tcZipFile, tnTarget)
*  Core routine. Returns the number of corrected fields, or -1 on error.
*-------------------------------------------------------------------------------
   LOCAL lnH, lnSize, lnTailLen, lcTail, lnEsig, lnEocdAbs
   LOCAL lnEntries, lnCdSize, lnCdOffset
   LOCAL lcCD, lnPos, n, lnChanged, lnRet
   LOCAL lcCDH, lcLFH, lnCdAbs, lnLhOff, lcLH
   LOCAL lnNlen, lnElen, lnClen

   IF VARTYPE(tnTarget) <> "N"
      tnTarget = 10
   ENDIF
   IF VARTYPE(tcZipFile) <> "C" OR NOT FILE(tcZipFile)
      RETURN -1
   ENDIF

   lcCDH = "PK" + CHR(1) + CHR(2)        && Central Directory Header signature
   lcLFH = "PK" + CHR(3) + CHR(4)        && Local File Header signature

   *-- Open read/write, unbuffered
   lnH = FOPEN(tcZipFile, 12)
   IF lnH < 0
      RETURN -1
   ENDIF

   lnRet     = -1                        && pessimistic: any break returns -1
   lnChanged = 0

   DO WHILE .T.                          && single-pass block for clean exits
      *-- File size: seek to end
      lnSize = FSEEK(lnH, 0, 2)
      IF lnSize < 22
         EXIT
      ENDIF

      *-- Read the trailing block and locate the EOCD signature (PK 05 06)
      lnTailLen = MIN(lnSize, 65557)
      =FSEEK(lnH, lnSize - lnTailLen, 0)
      lcTail = FREAD(lnH, lnTailLen)
      lnEsig = RAT("PK" + CHR(5) + CHR(6), lcTail)     && 1-based, within tail
      IF lnEsig = 0
         EXIT
      ENDIF
      lnEocdAbs = (lnSize - lnTailLen) + (lnEsig - 1)  && 0-based file offset

      *-- EOCD fields: entryCount(+10), cdSize(+12), cdOffset(+16)
      lnEntries  = GetWord(lcTail,  lnEsig + 10)
      lnCdSize   = GetDWord(lcTail, lnEsig + 12)
      lnCdOffset = GetDWord(lcTail, lnEsig + 16)

      *-- ZIP64 is not handled here (sentinel values) -> bail out cleanly
      IF lnEntries = 65535 OR lnCdOffset = 4294967295 OR lnCdSize = 4294967295
         EXIT
      ENDIF

      *-- Read the whole Central Directory at once (holds all offsets/lengths)
      =FSEEK(lnH, lnCdOffset, 0)
      lcCD = FREAD(lnH, lnCdSize)
      IF LEN(lcCD) < lnCdSize
         EXIT
      ENDIF

      lnPos = 1                          && 1-based, within lcCD
      FOR n = 1 TO lnEntries
         IF NOT (SUBSTR(lcCD, lnPos, 4) == lcCDH)
            EXIT                         && unexpected structure -> stop
         ENDIF

         *-- absolute file offset of this Central Directory header (0-based)
         lnCdAbs = lnCdOffset + (lnPos - 1)

         *-- version-needed in the Central Directory header (+6)
         IF GetWord(lcCD, lnPos + 6) <> tnTarget
            WriteWordAt(lnH, lnCdAbs + 6, tnTarget)
            lnChanged = lnChanged + 1
         ENDIF

         *-- offset of the matching Local File Header (CD header +42, 0-based)
         lnLhOff = GetDWord(lcCD, lnPos + 42)
         IF lnLhOff >= 0 AND lnLhOff + 6 <= lnSize
            =FSEEK(lnH, lnLhOff, 0)
            lcLH = FREAD(lnH, 6)         && signature(4) + version-needed(2)
            IF LEFT(lcLH, 4) == lcLFH
               *-- version-needed in the LFH (+4) -> position 5 in the 6-byte buffer
               IF GetWord(lcLH, 5) <> tnTarget
                  WriteWordAt(lnH, lnLhOff + 4, tnTarget)
                  lnChanged = lnChanged + 1
               ENDIF
            ENDIF
         ENDIF

         *-- advance to next CD header: 46 + nameLen(+28) + extraLen(+30) + commentLen(+32)
         lnNlen = GetWord(lcCD, lnPos + 28)
         lnElen = GetWord(lcCD, lnPos + 30)
         lnClen = GetWord(lcCD, lnPos + 32)
         lnPos  = lnPos + 46 + lnNlen + lnElen + lnClen
      ENDFOR

      lnRet = lnChanged                  && success
      EXIT
   ENDDO

   =FFLUSH(lnH)
   =FCLOSE(lnH)
   RETURN lnRet
ENDFUNC


*-------------------------------------------------------------------------------
PROCEDURE WriteWordAt(tnHandle, tnFileOffset, tnValue)
*  Write a 16-bit little-endian value at an absolute (0-based) file offset.
*-------------------------------------------------------------------------------
   =FSEEK(tnHandle, tnFileOffset, 0)
   =FWRITE(tnHandle, CHR(MOD(tnValue, 256)) + CHR(INT(tnValue / 256)))
ENDPROC


*-------------------------------------------------------------------------------
FUNCTION GetWord(tcStr, tnPos)            && 16-bit LE, 1-based position
   RETURN ASC(SUBSTR(tcStr, tnPos,     1)) + ;
          ASC(SUBSTR(tcStr, tnPos + 1, 1)) * 256
ENDFUNC


*-------------------------------------------------------------------------------
FUNCTION GetDWord(tcStr, tnPos)           && 32-bit LE, 1-based position
   RETURN ASC(SUBSTR(tcStr, tnPos,     1)) + ;
          ASC(SUBSTR(tcStr, tnPos + 1, 1)) * 256 + ;
          ASC(SUBSTR(tcStr, tnPos + 2, 1)) * 65536 + ;
          ASC(SUBSTR(tcStr, tnPos + 3, 1)) * 16777216
ENDFUNC
