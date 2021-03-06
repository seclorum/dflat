;**********************************************************
;*
;*	ORIC DFLAT
;*	Dolo Miah (@6502Nerd)
;*	Copyright (c) 2020
;*  Free to use for any non-commercial purpose subject to
;*  credit of original my authorship please!
;*
;*  KEYBOARD.S
;*	Keyboard driver code. It is very slow to scan so
;*	routines here do a basic scan for any key before finding
;*	the specific key. Still, it has a noticeable impact on
;*	CPU especially in dflat which checks the key after every
;*	keyword is executed.
;*	Rather than working off interrupts these routines just
;*	need to be called as needed. The T1 interrupt keeps
;*	track of keyboard timers for repeat delay and speed.
;*
;**********************************************************

	; ROM code
	code

;****************************************
;* init_keyboard
;* Initialise the keyboard settings
;****************************************
init_keyboard
	lda #KB_REP_DEL
	sta kb_rdel_tim
	lda #KB_REP_TIM
	sta kb_rep_tim
	lda #KB_DEBOUNCE
	sta kb_deb_tim
	lda #0
	sta kb_stat

	rts

;****************************************
;* kb_stick
;* Check for fire | down | up | right | left
;*        bit  4     3      2     1       0
;* Returns bit mask of keys pressed
;****************************************
kb_stick
	lda #0					; Result will be in A
	pha	
	; Select Row 4 only, all keys on this row
	lda #4
	sta IO_0+PRB
	ldy #4
	ldx #SND_REG_IOA		; AY Port A for columns
kb_stick_pos
	lda kb_stick_mask,y		; Get the column mask
	jsr snd_set				; Activate column
	lda IO_0+PRB			; Read Port B
	and #KB_SENSE			; Something pressed?
	cmp #KB_SENSE			; C=1 if set else 0
	pla
	rol a					; Get C in to A
	pha
	dey
	bpl kb_stick_pos		; Do all 5 positions
	pla						; Result in A
	rts

	
;****************************************
;* kb_any_key
;* Quick check for any key except shifts & ctrl
;* Carry = 1 means key pressed
;****************************************
kb_any_key
	; Select all columns except 4
	lda #0b00010000			; Deselect only col 4
	ldx #SND_REG_IOA		; On AY port A
	jsr snd_set

	ldy #7					; Start from row 7
kb_any_key_row
	sty IO_0+PRB			; Select row on port B
	nop
	nop
	
	lda IO_0+PRB			; Read Port B
	and #KB_SENSE			; Something pressed?
	bne kb_any_key_pressed
	dey						; If not then next row
	bpl kb_any_key_row		; Until all rows done
kb_any_key_none
	clc						; C=0 means not pressed
	rts
kb_any_key_pressed
	sec						; C=1 means pressed
	rts

;****************************************
;* kb_read_raw
;* Read keyboard
;* Y = Keyboard code
;* Carry = 1 means key found, 0 = no keys found
;****************************************
kb_read_raw
	jsr kb_any_key			; Quick check is anything down?
	bcc kb_read_nothing		; Don't bother if not
kb_read_raw_force
	ldy #0					; Start at column 0, row 0
kb_check_matrix
	tya
	and #0b00000111
	sta IO_0+PRB			; Select row from bits 210

	tya
	lsr a					; Get bits 543 for column
	lsr a
	lsr a

	cmp #4					; If col 4 then skip over (checked later)
	beq kb_skip_col4

	tax						; Index to the col mask
	lda kb_col_mask,x
	ldx #SND_REG_IOA		; Select Port A of AY
	jsr snd_set				; Set Port A to column mask
	nop
	nop
	lda IO_0+PRB			; Read Port B
	and #KB_SENSE			; Bit 3 is the sense
	bne kb_read_got
	iny
	cpy #64					; only 64 combinations
	bne kb_check_matrix
	; No key was sensed

kb_read_nothing
	ldy #0					; Raw key codes
	clc						; No key sensed flag
	rts
kb_read_got
	sec						; Key sensed flag
	rts
kb_skip_col4
	ldy #40					; 40=5*8 skips col 4
	bne kb_check_matrix		; Continue	

	
;****************************************
;* kb_scan_key
;* Scans for a key, returns zero for no key found
;* Processes caps and shift lock but these don't count as key presses
;* A = Key code
;****************************************
kb_scan_key
	jsr kb_read_raw			; Check if a key is sensed
	bcs kb_scan_decode		; go ahead and decode
	; If pressed nothing then reset timers
	lda kb_rdel_tim			; Reset repeat timer to initial delay
	sta kb_rep
	lda #0
	sta kb_raw				; Reset raw key settings
	sta kb_last				; And last key
kb_scan_wait
	sec						; Code not valid
	rts						; And done (A=0)	
kb_scan_decode
	; If got here then raw key is good
	sty kb_raw

	; Now to get a proper key code translated from raw

	; Check for shift and ctrl (not debounced!)
	lda #0b11101111			; Select column 4
	ldx #SND_REG_IOA		; On AY port A
	jsr snd_set

	; check shifted keys
	ldx #4					; Row 4 (left shift)
	stx IO_0+PRB			; Select row on port B
	nop
	nop

	lda IO_0+PRB			; Read Port B

	ldx #7					; Row 7 (right shift)
	stx IO_0+PRB			; Select row on port B
	nop
	nop

	ora IO_0+PRB			; Combine Port B
	ldx kb_table_std,y		; Pre-load standard key code in X
	and #KB_SENSE			; Bit 3 is the sense
	beq kb_read_noshift		; Skip over if no shift
	ldx kb_table_shift,y	; Load up standard key code mapping	
kb_read_noshift
	stx kb_code				; Save the mapped keycode
	; check ctrl key
	ldx #2					; Row 2 (ctrl key)
	stx IO_0+PRB			; Select row on port B
	nop
	nop

	lda IO_0+PRB			; Read Port B
	and #KB_SENSE
	beq kb_skip_ctrl
	lda kb_code
	and #0x1f				; Ctrl will result in codes 0 to 31
	sta kb_code				; Override the keycode
	beq kb_brk
	bpl	kb_do_repeat		; Check repeat (bpl is always true)
kb_skip_ctrl
	lda kb_stat				; Check caps lock
	and #KB_CAPSLK
	beq kb_do_repeat
	lda kb_code
	cmp #'a'				; If < 'a' then skip
	bcc kb_do_repeat
	cmp #'z'+1				; If > 'z' then skip
	bcs kb_do_repeat
	lda kb_code				; Get the actual code	
	eor #0x20				; Switch off bit 0x20
	sta kb_code
kb_do_repeat
	lda kb_code
	cmp kb_last				; Same key as last time?
	beq kb_handle_repeat	; If so, need to check repeat delays
	sta kb_last				; Make last code same as this
	clc						; Code valid
	rts
kb_handle_repeat
	ldx kb_rep				; Has repeat expired?
	bne	kb_in_repeat		; If not then still in repeat
	ldx kb_rep_tim			; Set repeat speed
	stx kb_rep
	sta kb_last				; Make last code same as this
	clc						; Code valid
	rts	
kb_in_repeat
	lda #0					; Don't emit a keycode
	sec
	rts
kb_brk
	SWBRK DFERR_OK

;****************************************
;* kb_get_key
;* Waits for a key press, C=1 synchronous
;* A = Key code, C=1 means valid
;****************************************
kb_get_key
	txa
	pha
	tya
	pha

kb_get_try	
	php
	jsr kb_scan_key
	bcc kb_scan_got_key
	plp						; No key, so check C
	bcs kb_get_try			; Keep looking if C
	sec						; Indicate key not valid
	
	pla
	tay
	pla
	tax
	lda #0
	
	rts
kb_scan_got_key
	plp						; Pull stack
	clc						; Indicate key valid

	pla
	tay
	pla
	tax
	
	lda kb_code
	
	rts
	
;****************************************
;* kb_table_std (no shift)
;* Each line is one column
;****************************************
kb_table_std
	db '7' ,'j' ,'m' ,'k' ,' ' ,'u' ,'y' ,'8'
	db 'n' ,'t' ,'6' ,'9' ,',' ,'i' ,'h' ,'l'
	db '5' ,'r' ,'b' ,';' ,'.' ,'o' ,'g' ,'0'
	db 'v' ,'f' ,'4' ,'-' ,0x0b,'p' ,'e' ,'/'
	db 0,0,0,0,0,0,0,0 ; Column 4 is shift and ctrl - no codes
	db '1' ,0x1b,'z' ,0   ,0x08,0x7f,'a' ,0x0d
	db 'x' ,'q' ,'2' ,0x5c,0x0a,']' ,'s' ,0
	db '3' ,'d' ,'c' ,0x27,0x09,'[' ,'w' ,'='

;* kb_table_shift (with shift)
kb_table_shift
	db '&' ,'J' ,'M' ,'K' ,' ' ,'U' ,'Y' ,'*'
	db 'N' ,'T' ,'^' ,'(' ,'<' ,'I' ,'H' ,'L'
	db '%' ,'R' ,'B' ,':' ,'>' ,'O' ,'G' ,')'
	db 'V' ,'F' ,'$' ,'_' ,0x0b,'P' ,'E' ,'?'
	db 0,0,0,0,0,0,0,0 ; Column 4 is shift and ctrl - no codes
	db '!' ,0x1b,'Z' ,0   ,0x08,0x7f,'A' ,0x0d
	db 'X' ,'Q' ,'@' ,'|' ,0x0a,'}' ,'S' ,0
	db '#' ,'D' ,'C' ,0x22,0x09,'{' ,'W' ,'+'

kb_col_mask
	db 0b11111110
	db 0b11111101
	db 0b11111011
	db 0b11110111
	db 0b11101111
	db 0b11011111
	db 0b10111111
	db 0b01111111

kb_stick_mask
	db 0b11011111		; Left 	= Bit 0
	db 0b01111111		; Right = Bit 1
	db 0b11110111		; Up	= Bit 2
	db 0b10111111		; Down	= Bit 3
	db 0b11111110		; Space	= Bit 4
