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

;AHH NOT CHECKING IF THERES NO MORE BYTES BEING SENT ON USART
;GOTTA FIGURE OUT FRAME FORMAT FOR SERIAL COMM (dont even think I can use avrdude)
	;if we do end up using a standalone script then the bootloader could send back info about fuses and stuff
;DO I CARE ABOUT INITAL STATE OF GPIO (would it be bad to have things as input by default? I guess not since its what the atmega does anyway but seems weird to me)
	;ask noid
;MIGHT WANNA #DEFINE SOME BETTER NAMES FOR THE REGISTERS (since most of them stay constant)
;MAKE SURE YOU'RE READING THE RIGHT PIN
;ADD ERROR HANDLING (send an error byte and spin forever)
;MAKE SURE YOU INIT EVERYTHING YOU NEED TO (BASICALLY clr EVERYTHING)
;STILL HAVE NO WAY OF SKIPPING RECV WORD WHEN QUEUE IS FULL (should be ez though)
;HOW LONG DOES IT TAKE TO DO SPM FOR BUFFER FILLING?? COULD I JUST SPAM BUFFER FILL SPM????
;IS THE SRAM 2048 BYTES OR 2000? PROBABLY 2048 TBH
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

.EQU PAGE_LENGTH = 64
.EQU NUM_PAGES = 252 ;not 256 because last 4 pages are the bootloader itself

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

;other register definitions
.DEF CURRENT_WORD_ADDR = Z ;address to place the current word we're inserting into the page buffer
.DEF CURRENT_WORD_ADDR_LO = R30
.DEF CURRENT_WORD_ADDR_HI = R31
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
	rjmp end_flash_write ;exit bootloader if button is not pressed

;turn on LED to indicate we're in the bootloader
	sbi DDRB, LED_PIN ;set LED_PIN as output
	sbi PORTB, LED_PIN ;turn LED on

;set up variables for program loading
	clr CURRENT_WORD_ADDR_LO
	clr CURRENT_WORD_ADDR_HI ;current word in flash that we're updating = 0
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



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                add word to queue
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;add word to queue (we already know that queue is not full and that it is not pointing outside the queue)
	st HEAD+, CURRENT_WORD_HI ;store first byte of received word in queue and move the head forward
	st HEAD+, CURRENT_WORD_LO ;also store 2nd byte and increment

;check if head should be looped back to 0
	cpi HEAD_LO, lo_byte QUEUE_SIZE ;check if lo byte of head indicates it might be at the end of the queue
	brne check_if_queue_full ;if lo byte of head can't be at end of queue, start doing flash stuff
	cpi HEAD_HI, hi_byte QUEUE_SIZE ;check if head is at end of queue
	brne check_if_queue_full ;if we're not at the end of the queue yet start doing flash stuff

;loop head back to beginning of queue
	clr HEAD_HI
	clr HEAD_LO



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                request next word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

check_if_queue_full:

;assume the queue is full by default
	ldi QUEUE_IS_FULL, 1 

;copy head and increase by 2
	movw GENERAL_PURPOSE_WORD_REG, HEAD ;copy head
	adiw GENERAL_PURPOSE_WORD_REG, 2 ;increase by 2

;check if HEAD is 2 bytes away from TAIL (queue is full)
	cp GENERAL_PURPOSE_REG_1, TAIL_LO ;check lo byte of incremented head copy
	brne check_if_queue_empty ;if lo byte of head can't be at end of queue, start trying to do flash stuff
	cp GENERAL_PURPOSE_REG_2, TAIL_HI ;check if head is at end of queue
	brne check_if_queue_empty ;if we're not at the end of the queue yet start trying to do flash stuff

;the queue is not full, so we can request another word from the sender
	send_byte REQUEST_NEXT_WORD
	clr QUEUE_IS_FULL ;indicate that there will be a new word to read on the next cycle



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                  update flash
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

check_if_queue_empty:
	cp HEAD_LO, TAIL_LO ;yet another 16 bit compare, this time checking if HEAD == TAIL
	brne CHECK NEXT THING ;if tail != head then we can move on to checking what kind of spm instruction we should do
	cp HEAD_HI, TAIL_HI
	brne CHECK NEXT THING 

;queue is empty (TAIL == HEAD)
	rjmp receive_word ;get another word in the queue (can't update flash with no queued words) 

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
	breq end_flash_write ;exit if last serial read was unsuccessful (all data has been transfered)
	cpi R3, NUM_PAGES ;check if we've written all flash except the bootloader
	brsh end_flash_write ;exit if max page number is reached

;write another page if bootloading is not done	
	inc R3 ;otherwise, write another page
	inc Z ;increment Z here since we didn't do it at the end of the last buffer load
	rjmp update_next_page



end_flash_write:
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



;args: 	1: register containing hi byte of word
;		2: register containing lo byte of word
;		3: 16 bit value to compare to
;		4: location to jump to if @0:@1 != @3
;.MACRO brne_word:
;	cpi @1, lo_byte @3 ;check if lo byte of word indicates it might be equal to @3
;	brne @4 ;if word can't @3 then branch to @4
;	cpi @2, hi_byte @3 ;check if word is equal to @3 for sure
;	brne @4 ;branch if it's not equal
;.ENDMACRO