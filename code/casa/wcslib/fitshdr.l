/*============================================================================
*
*   WCSLIB 4.1 - an implementation of the FITS WCS standard.
*   Copyright (C) 1995-2005, Mark Calabretta
*
*   WCSLIB is free software; you can redistribute it and/or modify it under
*   the terms of the GNU General Public License as published by the Free
*   Software Foundation; either version 2 of the License, or (at your option)
*   any later version.
*
*   WCSLIB is distributed in the hope that it will be useful, but WITHOUT ANY
*   WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
*   FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
*   details.
*
*   You should have received a copy of the GNU General Public License along
*   with WCSLIB; if not, write to the Free Software Foundation, Inc.,
*   59 Temple Place, Suite 330, Boston, MA  02111-1307, USA
*
*   Correspondence concerning WCSLIB may be directed to:
*      Internet email: mcalabre@atnf.csiro.au
*      Postal address: Dr. Mark Calabretta
*                      Australia Telescope National Facility, CSIRO
*                      PO Box 76
*                      Epping NSW 1710
*                      AUSTRALIA
*
*   Author: Mark Calabretta, Australia Telescope National Facility
*   $Id$
*=============================================================================
*
*   fitshdr.l is a Flex description file containing a lexical scanner
*   definition for extracting keywords and keyvalues from a FITS header.
*
*   It requires Flex v2.5.4 or later.
*
*   Refer to fitshdr.h for a description of the user interface and operating
*   notes.
*
*===========================================================================*/

/* Options. */
%option full
%option never-interactive
%option noyywrap

/* Keywords. */
KEYCHR	[-_A-Z0-9]
KW1	{KEYCHR}{1}" "{7}
KW2	{KEYCHR}{2}" "{6}
KW3	{KEYCHR}{3}" "{5}
KW4	{KEYCHR}{4}" "{4}
KW5	{KEYCHR}{5}" "{3}
KW6	{KEYCHR}{6}" "{2}
KW7	{KEYCHR}{7}" "{1}
KW8	{KEYCHR}{8}
KEYWORD	({KW1}|{KW2}|{KW3}|{KW4}|{KW5}|{KW6}|{KW7}|{KW8})

/* Keyvalue data types. */
LOGICAL	[TF]
INT32	[+-]?0*[0-9]{1,9}
INT64	[+-]?0*[0-9]{10,18}
INTVL	[+-]?0*[0-9]{19,}
INTEGER	[+-]?[0-9]+
FLOAT	[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?
ICOMPLX	\(" "*{INTEGER}" "*," "*{INTEGER}" "*\)
FCOMPLX	\(" "*{FLOAT}" "*," "*{FLOAT}" "*\)
STRING	'([^']|'')*'

/* Characters forming standard unit strings (jwBIQX are not used). */
UNITSTR \[[-+*/^(). 0-9a-zA-Z]+\]

/* Exclusive start states. */
%x VALUE INLINE UNITS COMMENT ERROR FLUSH

%{
#include <math.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "fitshdr.h"

#define YY_DECL int fitshdr(const char header[], int ncards, int nkeyids, \
                            struct fitskeyid keyids[], int *nreject, \
                            struct fitskey **keys)

#define YY_INPUT(inbuff, count, bufsize) \
	{ \
	  if (fitshdr_ncards) { \
	    strncpy(inbuff, fitshdr_hdr, 80); \
	    inbuff[80] = '\n'; \
	    fitshdr_hdr += 80; \
	    fitshdr_ncards--; \
	    count = 81; \
	  } else { \
	    count = YY_NULL; \
	  } \
	}

#ifdef DEBUG
  /* Print text as it is matched. */
  #define YY_USER_ACTION printf("Rule %03d: \"%s\"\n", yy_act, yytext);
#endif

/* These global variables are required by YY_INPUT. */
const char *fitshdr_hdr;
int  fitshdr_ncards;

/* Map status return value to message. */
const char *fitshdr_errmsg[] = {
   0,
   "Null fitskey pointer-pointer passed",
   "Memory allocation failed"};

void fitshdr_nullfill(char cptr[], int len);

%}

%%
	char *cptr, ctmp[72];
	int  blank, continuation, end, j, k, keyno;
	double dtmp;
	struct fitskey *kptr;
	struct fitskeyid *iptr;
	
	fitshdr_hdr = header;
	fitshdr_ncards = ncards;
	
	*nreject = 0;
	keyno = 0;
	
	if (keys == 0) {
	  return 1;
	}
	
	/* Allocate memory for the required number of fitskey structs. */
	/* Note that calloc() initializes allocated memory to zero.    */
	if (!(kptr = *keys = calloc(ncards, sizeof(struct fitskey)))) {
	  return 2;
	}
	
	/* Initialize keyids[]. */
	iptr = keyids;
	for (j = 0; j < nkeyids; j++, iptr++) {
	  iptr->count  = 0;
	  iptr->idx[0] = -1;
	  iptr->idx[1] = -1;
	}
	
	blank = 0;
	continuation = 0;
	end = 0;
	
	BEGIN(INITIAL);

^" "{80} {
	  /* Rule 001: A completely blank card. */
	  strncpy(kptr->keyword, yytext, 8);
	  yyless(0);
	  blank = 1;
	  BEGIN(COMMENT);
	}

^(COMMENT|HISTORY|" "{8}) {
	  /* Rule 002. */
	  strncpy(kptr->keyword, yytext, 8);
	  BEGIN(COMMENT);
	}

^END" "{77} {
	  /* Rule 003. */
	  strncpy(kptr->keyword, yytext, 8);
	  end = 1;
	  BEGIN(FLUSH);
	}

^END" "{5}=" "+ {
	  /* Rule 004: Illegal END card. */
	  strncpy(kptr->keyword, yytext, 8);
	  kptr->status |= FITSHDR_CARD;
	  BEGIN(VALUE);
	}

^END" "{5} {
	  /* Rule 005: Illegal END card. */
	  strncpy(kptr->keyword, yytext, 8);
	  kptr->status |= FITSHDR_CARD;
	  BEGIN(COMMENT);
	}

^{KEYWORD}=" "+ {
	  /* Rule 006. */
	  strncpy(kptr->keyword, yytext, 8);
	  BEGIN(VALUE);
	}

^CONTINUE"  "+{STRING} {
	  /* Rule 007: Continued string keyvalue. */
	  strncpy(kptr->keyword, yytext, 8);

	  if (keyno > 0 && (kptr-1)->type%10 == 8) {
	    /* Put back the string keyvalue. */
	    for (k = 10; yytext[k] != '\''; k++);
	    yyless(k);
	    continuation = 1;
	    BEGIN(VALUE);

	  } else {
	    /* Not a valid continuation. */
	    yyless(8);
	    BEGIN(COMMENT);
	  }
	}

^{KEYWORD} {
	  /* Rule 008: Keyword without value. */
	  strncpy(kptr->keyword, yytext, 8);
	  BEGIN(COMMENT);
	}

^.{8}=" "+ {
	  /* Rule 009: Illegal keyword, carry on regardless. */
	  strncpy(kptr->keyword, yytext, 8);
	  kptr->status |= FITSHDR_KEYWORD;
	  BEGIN(VALUE);
	}

^.{8}	{
	  /* Rule 010: Illegal keyword, carry on regardless. */
	  strncpy(kptr->keyword, yytext, 8);
	  kptr->status |= FITSHDR_KEYWORD;
	  BEGIN(COMMENT);
	}

<VALUE>" "*/\/ {
	  /* Rule 011: Null keyvalue. */
	  BEGIN(INLINE);
	}

<VALUE>{LOGICAL} {
	  /* Rule 012: Logical keyvalue. */
	  kptr->type = 1;
	  kptr->keyvalue.i = (*yytext == 'T');
	  BEGIN(INLINE);
	}

<VALUE>{INT32} {
	  /* Rule 013: 32-bit signed integer keyvalue. */
	  kptr->type = 2;
	  if (sscanf(yytext, "%d", &(kptr->keyvalue.i)) < 1) {
	    kptr->status |= FITSHDR_KEYVALUE;
	    BEGIN(ERROR);
	  }
	
	  BEGIN(INLINE);
	}

<VALUE>{INT64} {
	  /* Rule 014: 64-bit signed integer keyvalue (up to 18 digits). */
	  if (sscanf(yytext, "%lf", &dtmp) < 1) {
	    kptr->status |= FITSHDR_KEYVALUE;
	    BEGIN(ERROR);
	
	  } else if (INT_MIN <= dtmp && dtmp <= INT_MAX) {
	    /* Can be accomodated as a 32-bit signed integer. */
	    kptr->type = 2;
	    if (sscanf(yytext, "%d", &(kptr->keyvalue.i)) < 1) {
	      kptr->status |= FITSHDR_KEYVALUE;
	      BEGIN(ERROR);
	    }
	
	  } else {
	    /* 64-bit signed integer. */
	    kptr->type = 3;
	    #ifdef WCS_INT64
	      /* Native long long int is available. */
	      if (sscanf(yytext, "%Ld", &(kptr->keyvalue.k)) < 1) {
	        kptr->status |= FITSHDR_KEYVALUE;
	        BEGIN(ERROR);
	      }
	    #else
	      /* long long int implemented as int[3]. */
	      kptr->keyvalue.k[2] = 0;
	
	      sprintf(ctmp, "%%%dd%%9d", yyleng-9);
	      if (sscanf(yytext, ctmp, kptr->keyvalue.k+1,
	                 kptr->keyvalue.k) < 1) {
	        kptr->status |= FITSHDR_KEYVALUE;
	        BEGIN(ERROR);
	      } else if (*yytext == '-') {
	        kptr->keyvalue.k[0] *= -1;
	      }
	    #endif
	  }
	
	  BEGIN(INLINE);
	}

<VALUE>{INTVL} {
	  /* Rule 015: Very long integer keyvalue. */
	  kptr->type = 4;
	  strcpy(ctmp, yytext);
	  k = yyleng;
	  for (j = 0; j < 8; j++) {
	    /* Read it backwards. */
	    k -= 9;
	    if (k < 0) k = 0;
	    if (sscanf(ctmp+k, "%d", kptr->keyvalue.l+j) < 1) {
	      kptr->status |= FITSHDR_KEYVALUE;
	      BEGIN(ERROR);
	    }
	    if (*yytext == '-') kptr->keyvalue.l[j] *= -1;
	
	    if (k == 0) break;
	    ctmp[k] = '\0';
	  }
	
	  /* Can it be accomodated as a 64-bit signed integer? */
	  if (j == 2 && abs(kptr->keyvalue.l[2]) <=  9 &&
	                abs(kptr->keyvalue.l[1]) <=  223372036 &&
	                    kptr->keyvalue.l[0]  <=  854775807 &&
	                    kptr->keyvalue.l[0]  >= -854775808) {
	    kptr->type = 3;
	
	    #ifdef WCS_INT64
	      /* Native long long int is available. */
	      kptr->keyvalue.l[2] = 0;
	      if (sscanf(yytext, "%Ld", &(kptr->keyvalue.k)) < 1) {
	        kptr->status |= FITSHDR_KEYVALUE;
	        BEGIN(ERROR);
	      }
	    #endif
	  }

	  BEGIN(INLINE);
	}

<VALUE>{FLOAT} {
	  /* Rule 016: Float keyvalue. */
	  kptr->type = 5;
	  if (sscanf(yytext, "%lf", &(kptr->keyvalue.f)) < 1) {
	    kptr->status |= FITSHDR_KEYVALUE;
	    BEGIN(ERROR);
	  }
	
	  BEGIN(INLINE);
	}

<VALUE>{ICOMPLX} {
	  /* Rule 017: Integer complex keyvalue. */
	  kptr->type = 6;
	  if (sscanf(yytext, "(%lf,%lf)", kptr->keyvalue.c,
	      kptr->keyvalue.c+1) < 2) {
	    kptr->status |= FITSHDR_KEYVALUE;
	    BEGIN(ERROR);
	  }
	
	  BEGIN(INLINE);
	}

<VALUE>{FCOMPLX} {
	  /* Rule 018: Floating point complex keyvalue. */
	  kptr->type = 7;
	  if (sscanf(yytext, "(%lf,%lf)", kptr->keyvalue.c,
	      kptr->keyvalue.c+1) < 2) {
	    kptr->status |= FITSHDR_KEYVALUE;
	    BEGIN(ERROR);
	  }
	
	  BEGIN(INLINE);
	}

<VALUE>{STRING} {
	  /* Rule 019: String keyvalue. */
	  kptr->type = 8;
	  cptr = kptr->keyvalue.s;
	  strcpy(cptr, yytext+1);
	
	  /* Squeeze out repeated quotes. */
	  k = 0;
	  for (j = 0; j < 72; j++) {
	    if (k < j) {
	      cptr[k] = cptr[j];
	    }
	
	    if (cptr[j] == '\0') {
	      if (k) cptr[k-1] = '\0';
	      break;
	    } else if (cptr[j] == '\'' && cptr[j+1] == '\'') {
	      j++;
	    }
	
	    k++;
	  }
	
	  if (*cptr) {
	    /* Retain the initial blank in all-blank strings. */
	    fitshdr_nullfill(cptr+1, 71);
	  } else {
	    fitshdr_nullfill(cptr, 72);
	  }
	
	  BEGIN(INLINE);
	}

<VALUE>. {
	  /* Rule 020. */
	  kptr->status |= FITSHDR_KEYVALUE;
	  BEGIN(ERROR);
	}

<INLINE>" "*$ {
	  /* Rule 021. */
	  BEGIN(FLUSH);
	}

<INLINE>" "*\/" "*$ {
	  /* Rule 022. */
	  BEGIN(FLUSH);
	}

<INLINE>" "*\/" "* {
	  /* Rule 023. */
	  BEGIN(UNITS);
	}

<INLINE>" " {
	  /* Rule 024. */
	  kptr->status |= FITSHDR_COMMENT;
	  BEGIN(ERROR);
	}

<INLINE>. {
	  /* Rule 025: Keyvalue parsing must now also be suspect. */
	  kptr->status |= FITSHDR_COMMENT;
	  kptr->type = 0;
	  BEGIN(ERROR);
	}

<UNITS>{UNITSTR} {
	  /* Rule 026. */
	  kptr->ulen = yyleng;
	  yymore();
	  BEGIN(COMMENT);
	}

<UNITS>. {
	  /* Rule 027. */
	  yymore();
	  BEGIN(COMMENT);
	}

<COMMENT>.* {
	  /* Rule 028. */
	  strcpy(kptr->comment, yytext);
	  fitshdr_nullfill(kptr->comment, 84);
	  BEGIN(FLUSH);
	}

<ERROR>.* {
	  /* Rule 029. */
	  if (!continuation) kptr->type = -abs(kptr->type);
	
	  sprintf(kptr->comment, "%.80s", fitshdr_hdr-80);
	  kptr->comment[80] = '\0';
	  fitshdr_nullfill(kptr->comment+80, 4);
	
	  BEGIN(FLUSH);
	}

<FLUSH>.*\n {
	  /* Rule 030: Discard the rest of the input line. */
	  kptr->keyno = ++keyno;
	
	  /* Null-fill the keyword. */
	  kptr->keyword[8] = '\0';
	  fitshdr_nullfill(kptr->keyword, 12);
	
	  /* Do indexing. */
	  iptr = keyids;
	  for (j = 0; j < nkeyids; j++, iptr++) {
	    cptr = iptr->name;
	    cptr[8] = '\0';
	    fitshdr_nullfill(cptr, 12);
	    for (k = 0; k < 8; k++, cptr++) {
	      if (*cptr != '.' && *cptr != kptr->keyword[k]) break;
	    }
	
	    if (k == 8) {
	      /* Found a match. */
	      iptr->count++;
	      if (iptr->idx[0] == -1) {
	        iptr->idx[0] = keyno-1;
	      } else {
	        iptr->idx[1] = keyno-1;
	      }
	
	      kptr->keyno = -abs(kptr->keyno);
	    }
	  }
	
	  /* Deal with continued strings. */
	  if (continuation) {
	    /* Tidy up the previous string keyvalue. */
	    if ((kptr-1)->type == 8) (kptr-1)->type += 10;
	    cptr = (kptr-1)->keyvalue.s;
	    if (cptr[strlen(cptr)-1] == '&') cptr[strlen(cptr)-1] = '\0';

	    kptr->type = (kptr-1)->type + 10;
	  }
	
	  /* Check for cards following the END card. */
	  if (end && (end++ > 1) && !blank) {
	    kptr->status |= FITSHDR_TRAILER;
	  }
	  if (kptr->status) (*nreject)++;
	
	  kptr++;
	  blank = 0;
	  continuation = 0;
	
	  BEGIN(INITIAL);
	}

<<EOF>> {
	  /* Rule unnumbered: End-of-input. */
	  return 0;
	}

%%

/*--------------------------------------------------------------------------*/

void fitshdr_nullfill(char cptr[], int len)

{
  int j, k;

  /* Null-fill the string. */
  for (j = 0; j < len; j++) {
    if (cptr[j] == '\0') {
      for (k = j+1; k < len; k++) {
        cptr[k] = '\0';
      }
      break;
    }
  }

  for (k = j-1; k >= 0; k--) {
    if (cptr[k] != ' ') break;
    cptr[k] = '\0';
  }

  return;
}