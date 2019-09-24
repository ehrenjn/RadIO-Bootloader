;How to tell it to begin exeuction in bootloader section
	;"the Boot Reset Fuse can be programmed so that the Reset Vector is pointing to the Boot Flash 
	;	start address after a reset. In this case, the Boot Loader is started after a reset."
	;basically just make the boot reset fuse = 0 
	;	and it'll reset to whatever position is indicated by the BOOTSZ1 BOOTSZ0 fuses (the fuses that control where bootloader memory begins)
	;	I want to make the smallest bootloader possible on the 328p: 256 words
	;	to get a 256 word bootloader you set both BOOTSZ1 and BOOTSZ0 to 1
;how to lock bootloader section from being accessed via application memory:
	;set up the following fuses: BLB12 = 0, BLB11 = 0
	;this will make it impossible for any executing code to write to the bootloader section 
	;also makes interrupts unable to be invoked from bootloader (which we're disabling anyway)
	;also makes application code unable to read bootloader code

;MIGHT WANNA #DEFINE SOME BETTER NAMES FOR THE REGISTERS (since most of them stay constant)
;MAKE SURE YOU'RE READING THE RIGHT PIN
;ADD ERROR HANDLING (send an error byte and spin forever)
;MAKE SURE YOU INIT EVERYTHING YOU NEED TO (BASICALLY clr EVERYTHING)
;HOW LONG DOES IT TAKE TO DO SPM FOR BUFFER FILLING?? COULD I JUST SPAM BUFFER FILL SPM????
;IS THE SRAM 2048 BYTES OR 2000? PROBABLY 2048 TBH
;MAKE A VAR TO KEEP TRACK OF WHAT WORD YOU'RE ON (R2) thats only used for adding to buffer
;OH MAN I SHOULD JUST STORE A QUEUE SIZE VARIABLE AND THEN I WOULDNT HAVE TO DEAL WITH THE NASTY QUEUE OPs
	;to check if queue is empty you would just OR both current queue size bytes and check if it's 0
	;which is only 1 byte faster than doing a cpc...
	;and only shave off like 5 instructions from checking if queue is full (still need to do a 16 bit cp)
	;and you lose 2 instructions to incrementing and loweing the current queue size every round
	;so all in all its not really worth it, just figure out cpc
;WOULD BE FASTER IF I REQUESTED THE NEXT WORD BEFORE ADDING THE CURRENT WORD TO THE QUEUE BUT IT WOULD BE HARD TO IMPLEMENT (because I'd have to increase queue by 4 with looping)
;DONT THINK NUM_PAGES WILL EVER ACTUALLY GET USED ANYWHERE
;MAKE SURE YOU INCREASE Z, CLEAR THE BUFFER SIZE, AND CLEAR THE HAS BEEN ERASED BIT AFTER YOU WRITE THE PAGE
	;also make sure you set the erased flag at the end of a page erase
;IN THE FIRST TWO JUMPS WHEN IM RECIVING A WORD IM NOT SURE IF I SHOULD BE JUMPING TO CHECKING IF THE QUEUE IS FULL OR JUMP RIGHT TO FLASH WRITING, FIGURE IT OUT
	;the first one is definately wrong (or at least, the comment is)
	;might need to delete check_if_queue_full just because nothing ever jumps to it
;IVE SO FAR GOT NO WAY TO WRITE A PARTIALLY FILLED BUFFER TO THE FLASH
	;hint: right now you're not doing ANY spm if theres no data in the queue... but the only spm operation that requires the queue is filling the buffer!
;KIDNA NASTY THAT I NEED TO SUBTRACT PAGE_LENGTH (or just 1 because thatd work too) WHENEVER I ERASE OR WRITE FLASH, BUT I DONT THINK THERES A BETTER WAY 
	;only the word bits are used when writing to temp buff and only page bits are used for erase/write... so maybe you can figure something out
;EVERYTHING IS UNTESTED (of course)

;go to page 277 in atmega datasheet to read about "programming the flash"
;go to page 287 in datasheet for "Assembly Code Example for a Boot Loader"

;flash must be addressed in the Z register using pages and words
;a word is 2 bytes long, there are 64 words per page
;there are 256 pages
;when using Z to address a page, bits 13:6 specify a page and bits 5:0 specifify a word within that page
;   R31     R30
;xxpppppp ppwwwwww 

;you can only write to the flash one page at a time
;first fill the page buffer, then erase the old page, then write the new page.


.INCLUDE iodefs.asm

;gpio pins
.EQU BTN_IN_PIN = 0 ;pin that bootloader button is on
.EQU LED_PIN = 0 ;pin that the general purpose LED is on

;USART definitions and transmission bytes
.EQU REQUEST_NEXT_WORD = 'w' ;asks sender for next word of data
.EQU REQUEST_DISCONNECT = 'd' ;tells sender to disconnect
.EQU BAUD_RATE = 0 

;queue definitions
.EQU QUEUE_END = 2000 ;number of bytes in queue (not words!)
.DEF HEAD = X ;head of circular queue (address in sram to place the next word of data)
.DEF HEAD_LO = 
.DEF HEAD_HI =
.DEF TAIL = Y ;tail of queue (address in sram to find next queued word)
.DEF TAIL_LO = 
.DEF TAIL_HI =

;definitions for spm operations
.EQU PAGE_LENGTH = 64
.EQU NUM_PAGES = 252 ;not 256 because last 4 pages are the bootloader itself
.DEF CURRENT_PAGE_BUFFER_SIZE = R2 ;keeps track of how many words we've inserted into the page buffer 
.DEF PAGE_HAS_BEEN_ERASED = R3 ;1 if the current page has been erased, 0 otherwise

;other register definitions
.DEF LAST_BUFFERED_WORD_ADDR = Z ;address to place the LAST word that WAS inserted into the page buffer (last word instead of current word because I'm incrementing this one register to do all buffering/erasing/writing which means I need it to be 63 when I'm erasing/writing the 0th page instead of 64)
.DEF LAST_BUFFERED_WORD_LO = R30
.DEF LAST_BUFFERED_WORD_HI = R31
.DEF CURRENT_WORD_LO = R0 ;when adding a word to the page buffer we have to address it using R1:R0 
.DEF CURRENT_WORD_HI = R1

.DEF DONE_RECEIVING_DATA = R5 ;stores a 1 if we're done receiving data, 0 otherwise
.DEF QUEUE_IS_FULL = R6 ;store a 1 if the queue is full, 0 otherwise

.DEF GENERAL_PURPOSE_REG_1 = 
.DEF GENERAL_PURPOSE_REG_2 = 
.DEF GENERAL_PURPOSE_WORD_REG = GENERAL_PURPOSE_REG_2: GENERAL_PURPOSE_REG_1


.ORG SMALLBOOTSTART ;place this at the beginning of the smallest bootloader section (256 words large)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                initialization
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;disable all interrupts so currently bootloaded program can't interrupt bootloading process
	cli

;check if we're loading a program
	cbi DDRB, BTN_IN_PIN ;set the proper pin as input (should be default behavior anyway)
	nop ;must wait one clock cycle for input register to update after setting pins as input
	sbic PINB, BTN_IN_PIN ;if pin is high (button is pressed) then enter the bootloader
	rjmp exit_bootloader ;exit bootloader if button is not pressed

;turn on LED to indicate we're in the bootloader
	sbi DDRB, LED_PIN ;set LED_PIN as output
	sbi PORTB, LED_PIN ;turn LED on

;set up variables for program loading
	set LAST_BUFFERED_WORD_LO ;set instead of clr because it needs to be 0 after the first word is added to the buffer
	set LAST_BUFFERED_WORD_HI ;last word that was put in the page buffer was -1
	clr R3 ;current page number = 0
	clr DONE_RECEIVING_DATA ;not done receiving data

;init USART
	ldi R4, BAUD_RATE_HI 
	out UBRR0H, R4 ;init baud rate hi
	ldi R4, BAUD_RATE_LO
	out UBRR0L, R4 ;init baud rate lo
	ldi R4, 0b00011100 ;turn on both receiver and transmitter, also use 9 bit communication
	out UCSR0B, R4 ;save USART setting
	ldi R4, 0b00000110 ;9 bit communication mode, 1 stop bit, no parity bit, async USART mode
	out UCSR0C, R4

;request first word of data
	send_byte REQUEST_NEXT_WORD



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                receive a word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

receive_word:
	cpi DONE_RECEIVING_DATA, 1 ;check if we're done receiving data
	breq check_if_queue_full ;if we're done, jump right to updating the flash

;if queue was full last round, check if it still is (instead of receiving a word)
	cpi QUEUE_IS_FULL, 1 ;check if queue is full
	breq check_if_queue_full ;if it's full, see if it still is

wait_for_byte_1:	
	sbis UCSR0A, 7 ;see if there is some unread data in USART 
	rjmp wait_for_byte_1 ;if theres no unread data then keep waiting

;read received data
	in CURRENT_WORD_HI, UDR0 ;read byte from USART
	sbic UCSR0B, 1 ;check if bit 9 of data is a 1
	ldi DONE_RECEIVING_DATA, 1 ;if bit 9 of data was a 1, record it

wait_for_byte_2:	
	sbis UCSR0A, 7 ;see if there is some unread data in USART 
	rjmp wait_for_byte_2 ;if theres no unread data then keep waiting

;read received data, no need to check bit 9 this time
	in CURRENT_WORD_LO, UDR0 ;read byte from USART

;add word to queue (we already know that queue is not full and that it is not pointing outside the queue)
	st HEAD+, CURRENT_WORD_HI ;store first byte of received word in queue and move the head forward
	st HEAD+, CURRENT_WORD_LO ;also store 2nd byte and increment

;reset head to 0 if it has reached the end of the queue
	clear_word_if_equal HEAD_HI, HEAD_LO, QUEUE_END



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               request next word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

check_if_queue_full:

;assume the queue is full by default
	ldi QUEUE_IS_FULL, 1 

;copy head and increase by 2
	movw GENERAL_PURPOSE_WORD_REG, HEAD ;copy head
	adiw GENERAL_PURPOSE_WORD_REG, 2 ;increase by 2

;loop back to 0 if HEAD+2 reaches the end of the queue
	clear_word_if_equal GENERAL_PURPOSE_REG_2, GENERAL_PURPOSE_REG_1, QUEUE_END

;check if (HEAD + 2) % QUEUE_END == TAIL
	cp GENERAL_PURPOSE_REG_1, TAIL_LO ;check lo byte of incremented head copy
	cpc GENERAL_PURPOSE_REG_2, TAIL_HI ;check if head is at end of queue (cpc instruction works in this context because it only sets the z flag if z was already 1)
	breq check_if_queue_empty ;queue is full, lets do flash stuff but without requesting another byte

;the queue is not full, so we can request another word from the sender
	send_byte REQUEST_NEXT_WORD
	clr QUEUE_IS_FULL ;indicate that there will be a new word to read on the next cycle



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                         figure out how to update flash
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

check_if_queue_empty:
	cp HEAD_LO, TAIL_LO ;yet another 16 bit compare, this time checking if HEAD == TAIL
	cpc HEAD_HI, TAIL_HI ;compare with carry (so that result of lo byte cp is taken into account)
	breq receive_word ;the queue is empty so we need to get another word in there (can't update flash with no queued words) 

;check if we can do spm
	sbic SPMCSR, 0 ;check if spm is still going, skip next instruction if it's not
	rjmp receive_word ;we can't do any spm so get the next word instead

;check if page buffer is full yet
	cpi CURRENT_PAGE_BUFFER_SIZE, PAGE_LENGTH 
	brne fill_page_buffer ;if page buffer isn't full then we have to keep filling it up before doing other spm

;check if we've erased the current page yet
	cpi PAGE_HAS_BEEN_ERASED, 1 ;check if page has been erased
	brne erase_page ;erase page if it hasn't been erased yet

;write the page (since we've already done everything else)
	ldi R2, 0b00000101 ;enable SPM, write mode
	out SPMCSR, R2
	spm ;write the page




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                              fill the page buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

fill_page_buffer:

;dequeue latest word
	ld CURRENT_WORD_HI, TAIL+ ;dequeue first byte and move tail forward
	ld CURRENT_WORD_LO, TAIL+ ;dequeue 2nd byte and move tail forward

;loop tail back to beginning of queue if need be
	clear_word_if_equal TAIL_HI, TAIL_LO, QUEUE_END

;increase word counts
	inc CURRENT_PAGE_BUFFER_SIZE ;track the size of the page buffer
	adiw LAST_BUFFERED_WORD, 1 ;increase this BEFORE adding to the buffer because spm instruction needs the address for the current word in Z to work

;add word to page buffer
	sbi SPMCSR, 0 ;enable SPM, page buffer fill mode
	spm ;add word to temporary page buffer

;restart main loop
	rjmp receive_word



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                  update flash
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

update_next_page:
	ld R2, 0 ;current word number

fill_page_buffer:
	receive_byte R1 ;store first byte of next instruction word in R1:R0 (have to use R0 and R1)
	cpi R5, 1 ;check if first byte was read successfully 
	breq write_page ;if first byte wasn't read properly then we have nothing else to put in the buffer, just write the page
	receive_byte R0 ;even if we don't receive a 2nd byte we cant write the page yet because we've still received one byte, so we need to add that to the page buffer before writing the page

add_word_to_page_buffer:
	ldi R4, 1
	out SPMCSR, R4 ;enable SPM, page buffer fill mode
	spm ;add instruction to temporary page buffer

;check if it's time to write the page
	cpi R2, PAGE_LENGTH ;current word number - PAGE_LENGTH
	brsh write_page ;write page if whole page is written to buffer
	cpi R5, 1 ;check if last serial byte was read successfully 
	breq write_page ;if there was an error with the last byte then we've received all data so it's time to write the page

;keep filling buffer, it's not yet time to write the page
	inc R2 ;continue filling page buffer
	inc Z
	rjmp fill_page_buffer



write_page:
	ldi R2, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, R2
	spm ;erase the page

wait_erase_complete:
	sbic SPMCSR, 0 ;skip next instruction if bit 0 of SPMCSR is cleared
	rjmp wait_erase_complete ;if SPM is still going, keep waiting

;write the current buffer to flash
	ldi R2, 0b00000101 ;enable SPM, write mode
	out SPMCSR, R2
	spm ;write the page

wait_write_complete:
	sbic SPMCSR, 0 ;skip next instruction if bit 0 of SPMCSR is cleared
	rjmp wait_write_complete ;if SPM is still going, keep waiting

;check if bootloading is done
	cpi R5, 1 ;check if last serial byte was read successfully 
	breq exit_bootloader ;exit if last serial read was unsuccessful (all data has been transfered)
	cpi R3, NUM_PAGES ;check if we've written all flash except the bootloader
	brsh exit_bootloader ;exit if max page number is reached

;write another page if bootloading is not done	
	inc R3 ;otherwise, write another page
	inc Z ;increment Z here since we didn't do it at the end of the last buffer load
	rjmp update_next_page



exit_bootloader:
	cbi PORTB, LED_PIN ;turn off LED to indicate we're no longer in the bootloader
	jmp 0 ;start uploaded program





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                              macros and functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;



;args: 1: byte to transmit
;trashes: R4
.MACRO send_byte:

wait_for_empty_transmit_buffer:
	sbis UCSR0A, 5 ;check if transmit data register is empty
	rjmp wait_for_empty_transmit_buffer ;if full, keep waiting

;load/send data
	cbi UCSR0B, 0 ;always set 9th bit to 0, it's only used when receiving data
	ldi R4, @0
	out UDR0, R4

.ENDMACRO



;args: 1: word to find lo byte of
;return: lo byte of arg 1
.MACRO lo_byte:
	(@0 & 0xFF)
.ENDMACRO

;args: 1: word to find hi byte of
;return: hi byte of input
.MACRO hi_byte:
	(@0 >> 8)
.ENDMACRO



;args: 	0: register containing hi byte of input word
;		1: register containing lo byte of input word
;		2: immediate word to compare @0:@1 to
;return: if @0:@1 == @2 then @0:@1 is cleared to 0. otherwise, nothing happens
.MACRO clear_word_if_equal:

;check if input word should be cleared
	cpi @1, lo_byte @2 ;check lo byte of input registers
	brne return\@: ;return if lo byte register differs from comparison word
	cpi @0, hi_byte @2 ;can't use cpc instruction because I'm comparing to an immediate 
	brne return\@: ;words aren't the same, return

;clear the input registers
	clr @0
	clr @1

return\@: ;looks weird because I have to make every use of this macro spit out a unique label here

.ENDMACRO