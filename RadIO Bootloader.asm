;How to tell it to begin exeuction in bootloader section
	;"the Boot Reset Fuse can be programmed so that the Reset Vector is pointing to the Boot Flash 
	;	start address after a reset. In this case, the Boot Loader is started after a reset."
	;basically just make the boot reset fuse = 0 
	;	and it'll reset to whatever position is indicated by the BOOTSZ1 BOOTSZ0 fuses (the fuses that control where bootloader memory begins)
	;	I want to make the smallest bootloader possible on the 328p: 256 words
	;	to get a 256 word bootloader you set both BOOTSZ1 and BOOTSZ0 to 1
;how to lock bootloader section from being accessed via application memory:
	;set up the following lock bits: BLB12 = 0, BLB11 = 0
	;this will make it impossible for any executing code to write to the bootloader section 
	;also makes interrupts unable to be invoked from bootloader (which we're disabling anyway)
	;also makes application code unable to read bootloader code

;MAKE SURE YOU'RE READING AND WRITING TO THE RIGHT PINS
;MAKE SURE YOU INIT EVERYTHING YOU NEED TO (BASICALLY clr EVERYTHING)
;WE MIGHT ACCIDENTLY TOSS IN 1-2 EXTRA NULL BYTES AT THE END OF APPLICATION MEMORY BECAUSE OF HOW THE RECEIVING WORKS, BE AWARE OF THIS WHILE TESTING
;HOW LONG DOES IT TAKE TO DO SPM FOR BUFFER FILLING?? COULD I JUST SPAM BUFFER FILL SPM????
	;if you can spam you can simply change the rjmp at the end of the fill buffer section to jump back to the start of spm instead of receive byte
;WOULD BE FASTER IF I REQUESTED THE NEXT WORD BEFORE ADDING THE CURRENT WORD TO THE QUEUE BUT IT WOULD BE HARD TO IMPLEMENT (because I'd have to increase queue by 4 with looping)
;DONT THINK NUM_PAGES WILL EVER ACTUALLY GET USED ANYWHERE
;MIGHT HAVE TO CLEAR SOME USART REGISTERS IN THE ERROR FUNCTION (SO THAT IM ABLE TO SEND DATA)
;FINISH DEFINITIONS

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
.EQU ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR = 'o' ;tells sender that the program that is being bootloaded is too long, or the bootloader messed up and tried to overwrite it's own memory
.EQU BAUD_RATE = 0 
.DEF USART_SEND_REG = 

;queue definitions
.EQU QUEUE_END = 2048 ;number of bytes in queue (not words!)
.DEF HEAD = X ;head of circular queue (address in sram to place the next word of data)
.DEF HEAD_LO = 
.DEF HEAD_HI =
.DEF TAIL = Y ;tail of queue (address in sram to find next queued word)
.DEF TAIL_LO = 
.DEF TAIL_HI =

;definitions for spm operations
.EQU PAGE_LENGTH = 64
.DEF CURRENT_PAGE_BUFFER_SIZE = R2 ;keeps track of how many words we've inserted into the page buffer 
.DEF PAGE_HAS_BEEN_ERASED = R3 ;1 if the current page has been erased, 0 otherwise

.EQU ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN = SMALLBOOTSTART ;bootloader is not allowed to write to this address or beyond (or else it would destroy it's own code)
.DEF LAST_BUFFERED_WORD_ADDR = Z ;address to place the LAST word that WAS inserted into the page buffer (last word instead of current word because I'm incrementing this one register to do all buffering/erasing/writing which means I need it to be 63 when I'm erasing/writing the 0th page instead of 64)
.DEF LAST_BUFFERED_WORD_ADDR_LO = R30
.DEF LAST_BUFFERED_WORD_ADDR_HI = R31
.DEF CURRENT_WORD_LO = R0 ;when adding a word to the page buffer we have to address it using R1:R0 
.DEF CURRENT_WORD_HI = R1

;other register definitions
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
	ser LAST_BUFFERED_WORD_ADDR_LO ;set instead of clr because it needs to be 0 after the first word is added to the buffer
	ser LAST_BUFFERED_WORD_ADDR_HI ;last word that was put in the page buffer was -1
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
	ldi USART_SEND_REG, REQUEST_NEXT_WORD
	rcall send_byte



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                receive a word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

receive_word:
	cpi DONE_RECEIVING_DATA, 1 ;check if we're done receiving data
	breq check_if_spm_done ;if we're done, jump right to updating the flash

;if queue was full last round, then we didn't request a new word. try to request a new word (instead of receiving a word)
	cpi QUEUE_IS_FULL, 1 ;check if queue was full
	breq try_to_request_next_word ;if was full, see if it still is

;read in bytes, set DONE_RECEIVING_DATA bit if a disconnect bit is received
	receive_byte CURRENT_WORD_HI, DONE_RECEIVING_DATA
	receive_byte CURRENT_WORD_LO, DONE_RECEIVING_DATA

;add word to queue (we already know that queue is not full and that it is not pointing outside the queue)
	st HEAD+, CURRENT_WORD_HI ;store first byte of received word in queue and move the head forward
	st HEAD+, CURRENT_WORD_LO ;also store 2nd byte and increment

;reset head to 0 if it has reached the end of the queue
	clear_word_if_equal HEAD_HI, HEAD_LO, QUEUE_END



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               request next word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

try_to_request_next_word:

;check if we're still receiving data
	cp DONE_RECEIVING_DATA, 1 
	brne start_queue_full_check ;start checking queue if we're not done receiving data

;disconnect from sender and don't try to request another word (we are done receiving data)
	ldi USART_SEND_REG, REQUEST_DISCONNECT
	rcall send_byte ;send request to disconnect
	rjmp check_if_spm_done ;skip the rest of word requesting, start doing spm

start_queue_full_check:
	ldi QUEUE_IS_FULL, 1 ;assume the queue is full by default

;copy head and increase by 2
	movw GENERAL_PURPOSE_WORD_REG, HEAD ;copy head
	adiw GENERAL_PURPOSE_WORD_REG, 2 ;increase by 2

;loop back to 0 if HEAD+2 reaches the end of the queue
	clear_word_if_equal GENERAL_PURPOSE_REG_2, GENERAL_PURPOSE_REG_1, QUEUE_END

;check if (HEAD + 2) % QUEUE_END == TAIL
	cp GENERAL_PURPOSE_REG_1, TAIL_LO ;check lo byte of incremented head copy
	cpc GENERAL_PURPOSE_REG_2, TAIL_HI ;check if head is at end of queue (cpc instruction works in this context because it only sets the z flag if z was already 1)
	breq check_if_spm_done ;queue is full, lets do flash stuff but without requesting another byte

;the queue is not full, so we can request another word from the sender
	ldi USART_SEND_REG, REQUEST_NEXT_WORD
	rcall send_byte
	clr QUEUE_IS_FULL ;indicate that there will be a new word to read on the next cycle



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                         figure out how to update flash
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;if spm is done:
	;buffer fill can occur when (buffer is not full && queue is not empty)
	;an erase can occur when: (buffer is full || (queue is empty && we're done receiving data))
	;a write can occur when: (erase can occur && erase is done)


check_if_spm_done:
	sbic SPMCSR, 0 ;check if spm is still going, skip next instruction if it's not
	rjmp receive_word ;we can't do any spm so get the next word instead

;if the old page has been erased, write the new page 
	cpi PAGE_HAS_BEEN_ERASED, 1 ;check if page has been erased
	breq write_page ;if it's been erased then it must be time to write

;else if the page buffer is full we should erase the old page 
	cpi CURRENT_PAGE_BUFFER_SIZE, PAGE_LENGTH 
	breq erase_page ;if page buffer is full then it's time to erase

;else if the queue is not empty we need to buffer whats in the queue
	cp HEAD_LO, TAIL_LO ;checking if HEAD == TAIL
	cpc HEAD_HI, TAIL_HI ;compare with carry (so that result of lo byte cp is taken into account)
	brne fill_page_buffer ;the queue is not empty, so lets buffer the next word

;else if we're done receiving data then we need to start erasing (since we already know theres no more data coming, we've buffered all we can, and no page erase has occured yet)
	cpi DONE_RECEIVING_DATA, 1
	breq erase_page

;else we can't do any spm
	rjmp receive_word ;restart the main loop



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               fill the page buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

fill_page_buffer:

;dequeue latest word
	ld CURRENT_WORD_HI, TAIL+ ;dequeue first byte and move tail forward
	ld CURRENT_WORD_LO, TAIL+ ;dequeue 2nd byte and move tail forward

;loop tail back to beginning of queue if need be
	clear_word_if_equal TAIL_HI, TAIL_LO, QUEUE_END

;increase word counts
	inc CURRENT_PAGE_BUFFER_SIZE ;track the size of the page buffer
	adiw LAST_BUFFERED_WORD_ADDR, 1 ;increase this BEFORE adding to the buffer because spm instruction needs the address for the current word in Z to work

;add word to page buffer
	sbi SPMCSR, 0 ;enable SPM, page buffer fill mode
	spm ;add word to temporary page buffer

;restart main loop
	rjmp receive_word



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                  erase page
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

erase_page:

;check if we're trying to overwrite the bootloader itself
	ldi GENERAL_PURPOSE_REG_1, lo_byte ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN
	cp LAST_BUFFERED_WORD_ADDR_LO, GENERAL_PURPOSE_REG_1 ;compare LAST_BUFFERED_WORD_ADDR and ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN
	ldi GENERAL_PURPOSE_REG_1, hi_byte ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN
	cpc LAST_BUFFERED_WORD_ADDR_HI, GENERAL_PURPOSE_REG_1
	
;if we're trying to overwrite the bootloader then throw an error
	ldi USART_SEND_REG, ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR ;prepare error byte for sending
	brsh error ;if LAST_BUFFERED_WORD_ADDR >= ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN then throw the error

;erase the page
	ldi GENERAL_PURPOSE_REG_1, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, GENERAL_PURPOSE_REG_1
	spm ;erase the page

;set a bit so we know the erase command for the current page has gone through
	ldi PAGE_HAS_BEEN_ERASED, 1

;restart main loop
	rjmp receive_word



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                   write page
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

write_page:

;write the current page indicated by LAST_BUFFERED_WORD_ADDR
	ldi GENERAL_PURPOSE_REG_1, 0b00000101 ;enable SPM, write mode
	out SPMCSR, GENERAL_PURPOSE_REG_1
	spm ;write the page

;reset all the variables needed to do another spm
	clr CURRENT_PAGE_BUFFER_SIZE ;page buffer is now 0
	clr PAGE_HAS_BEEN_ERASED ;next page has not yet been erased

;restart main loop
	rjmp receive_word



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                exit bootloader
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

error: ;reports the byte in USART_SEND_REG back to sender then spins forever
	rcall send_byte
panic_forever: ;infinite loop
	rjmp panic_forever


exit_bootloader: ;clean exit
	cbi PORTB, LED_PIN ;turn off LED to indicate we're no longer in the bootloader
	jmp 0 ;start uploaded program





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                           USART macros and functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: USART_SEND_REG: byte to transmit
send_byte:

wait_for_empty_transmit_buffer:
	sbis UCSR0A, 5 ;check if transmit data register is empty
	rjmp wait_for_empty_transmit_buffer ;if full, keep waiting

;send data
	cbi UCSR0B, 0 ;always set 9th bit to 0, it's only used when receiving data
	out UDR0, USART_SEND_REG ;begin sending

;return
	ret



;args:	0: register in which to save the received byte
;		1: register in which to save the 9th bit of data
.MACRO receive_byte:

wait_for_byte\@:	
	sbis UCSR0A, 7 ;see if there is some unread data in USART 
	rjmp wait_for_byte\@ ;if theres no unread data then keep waiting

;make sure there were no errors
	in USART_SEND_REG, UCSR0A ;load status into USART_SEND_REG so I can send an asap error
	andi USART_SEND_REG, 0b00011100 ;mask out all bits except errors
	lsr USART_SEND_REG, 2 ;shift errors into lower 3 bits (for convenience on the receiving end)
	brne error ;throw an error if we have any error bits

;read received data
	sbic UCSR0B, 1 ;check if bit 9 of data is a 1
	ldi @1, 1 ;if bit 9 of data was a 1, record it
	in @0, UDR0 ;read byte from USART

.ENDMACRO



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                             general purpose macros
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

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