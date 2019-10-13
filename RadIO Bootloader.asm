;before uploading the bootloader the following fuses must be changed:
	;BOOTRST must be *programmed* (set to 0)
		;this fuse determines if the mcu begins exectution in the bootloader section instead of address 0
	;BOOTSZ1 and BOOTSZ0 must be *unprogrammed* (set to 1)
		;these two fuses control WHERE the bootloader section begins in memory
		;setting them both to 1 creates the smallest bootloader space possible on the 328p (256 words)

;it is reccomend to also set up the following lock bits after the bootloader is uploaded to stop application code from erasing the bootloader:
	;*unprogram* BLB12 and BLB11 (set them to 0)
		;this will make it impossible for any executing code to write to the bootloader section 
		;also makes interrupts unable to be invoked from bootloader (which we're not using anyway)
		;also makes application code unable to read bootloader code


;MAKE SURE YOU'RE READING AND WRITING TO THE RIGHT PINS
;WE MIGHT ACCIDENTLY TOSS IN 1-2 EXTRA NULL BYTES AT THE END OF APPLICATION MEMORY BECAUSE OF HOW THE RECEIVING WORKS, BE AWARE OF THIS WHILE TESTING
;HOW LONG DOES IT TAKE TO DO SPM FOR BUFFER FILLING?? COULD I JUST SPAM BUFFER FILL SPM????
	;if you can spam you can simply change the rjmp at the end of the fill buffer section to jump back to the start of spm instead of receive byte
;WOULD BE FASTER IF I REQUESTED THE NEXT WORD BEFORE ADDING THE CURRENT WORD TO THE QUEUE BUT IT WOULD BE HARD TO IMPLEMENT (because I'd have to increase queue by 4 with looping)

;FOR WHATEVER REASON ITS NOT WAITING FOR SPM TO BE DONE?? PERHAPS IM NOT DOING SPM RIGHT, LOOK AT IT AGAIN
	;could just be that the memory reader is junked... maybe try loading a 1 instruction program instead 
	;(init the direction stuff BEFORE you exit the bootloader so the app just turns the led on)
	;OH WAIT BUT BAUD IS ONLY 2400 SO IT PROBABLY NEVER NEEDS TO WAIT TO DO SPM...
		;put a loop right after an spm command that counts up in the temp reg and then sends the total once spm is done (max out count at 255) 
;IF THIS DOUBLE Z THING WORKS OUT THEN ILL NEED TO DOUBLE THE ILLEGAL ADDRESS THING TOO...
	;ALSO UPDATE YOUR COMMENTS (ESPECIALLY AT THE END OF THE INTRO)
;YO I DONT THINK THE EDGE CASE WRITE THING ACTUALLY WORKS?? BUT IDK, TEST IT OUT A BIT, MAYBE ITS JUST NOT WRITING POST DISCONNECT BYTES??
	;seems to erase but not write
;DURING PAGE WRITE: "Other bits in the Z-pointer must be written to zero during this operation" !!!!!!!!!!!!!!!!!!!!
	;CHANGE LAST_BUFFERED_WORD_ADDR TO NEXT_BUFFERED_WORD_ADDR
;AHHHH YOUR NEW WAY OF ADDRESSING Z WONT WORK BECAUSE ALWAYS SUBTRACTING THE PAGE LENGTH WILL SUBTRACT TOO MUCH DATA ON THE LAST WRITE!!!
	;INSTEAD YOU SHOULD USE CURRENT_PAGE_BUFFER_SIZE (make it count in bytes)
	;or you can use some kind of bitmask if you find that easier, think about it

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


;gpio pins
.EQU BTN_IN_PIN = 1 ;pin that bootloader button is on
.EQU LED_PIN = 0 ;pin that the general purpose LED is on

;USART definitions and transmission bytes
.EQU REQUEST_NEXT_WORD = 'w' ;asks sender for next word of data
.EQU REQUEST_DISCONNECT = 'd' ;tells sender to disconnect
.EQU ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR = 'o' ;tells sender that the program that is being bootloaded is too long, or the bootloader messed up and tried to overwrite it's own memory
.EQU BAUD_RATE = 2400 ;target baud rate
.EQU OSC_FREQ = 16000000 ;clock rate of mcu
.EQU BAUD_BITS = (OSC_FREQ / BAUD_RATE / 16) - 1 ;the actual bits that must be writted to the baud rate registers
#define USART_SEND_REG R20

;queue definitions
.EQU STACK_SIZE = 20 ;need to know how big the stack is so the queue doesn't wipe it out (also needs to be a even number so that the queue doesn't get in a weird state)
.EQU QUEUE_START = 0x100 ;sram only actually starts at 0x100, before that is memory mapped stuff
.EQU QUEUE_END = 0x900 - STACK_SIZE ;sram contains 2048 (0x800) bytes (need to subtract stack size so that the queue doesn't destroy the stack)
#define HEAD X ;head of circular queue (address in sram to place the next word of data)
#define HEAD_LO R26
#define HEAD_HI R27
#define TAIL Y ;tail of queue (address in sram to find next queued word)
#define TAIL_LO R28
#define TAIL_HI R29
#define QUEUE_IS_FULL R19 ;store a 1 if the queue is full, 0 otherwise

;definitions for spm operations
.EQU PAGE_LENGTH = 128 ;length of a page in bytes
#define CURRENT_PAGE_BUFFER_SIZE R16 ;keeps track of how many words we've inserted into the page buffer 
#define PAGE_HAS_BEEN_ERASED R17 ;1 if the current page has been erased, 0 otherwise

.EQU ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN = SMALLBOOTSTART ;bootloader is not allowed to write to this address or beyond (or else it would destroy it's own code)
#define LAST_BUFFERED_WORD_ADDR Z ;address to place the LAST word that WAS inserted into the page buffer (last word instead of current word because I'm incrementing this one register to do all buffering/erasing/writing which means I need it to be 63 when I'm erasing/writing the 0th page instead of 64)
#define LAST_BUFFERED_WORD_ADDR_LO R30
#define LAST_BUFFERED_WORD_ADDR_HI R31
#define CURRENT_WORD_LO R0 ;when adding a word to the page buffer we have to address it using R1:R0 
#define CURRENT_WORD_HI R1

;other register definitions
#define DONE_RECEIVING_DATA R18 ;stores a 1 if we're done receiving data, 0 otherwise
#define GENERAL_PURPOSE_REG_1 R24 ;using R24 and R25 because they're the only non X/Y/Z registers that can be used with an ADIW instruction
#define GENERAL_PURPOSE_REG_2 R25 ;these 2 regs are for storing any random values
#define GENERAL_PURPOSE_WORD_REG GENERAL_PURPOSE_REG_2: GENERAL_PURPOSE_REG_1
#define TEMP_REG R21 ;used for storing values that will be used very soon, ie in an instruction or 2. I should always be able to easily know if this register is available or not just by glancing at nearby instructions





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                             general purpose macros
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: word: word to find lo byte of
;return: lo byte of arg 1
#define lo_byte(word) (word & 0xFF)

;args: word: word to find hi byte of
;return: hi byte of input
#define hi_byte(word) (word >> 8)



;args: 	0: register containing hi byte of input word
;		1: register containing lo byte of input word
;		2: immediate word to compare @0:@1 to
;		3: immediate word to reset the registers to
;return: if @0:@1 == @2 then @0:@1 is set to @3. otherwise, nothing happens
.MACRO reset_word_if_equal

;check if input word should be cleared
	cpi @1, lo_byte(@2) ;check lo byte of input registers
	brne return ;return if lo byte register differs from comparison word
	cpi @0, hi_byte(@2) ;can't use cpc instruction because I'm comparing to an immediate 
	brne return ;words aren't the same, return

;clear the input registers
	ldi @1, lo_byte(@3)
	ldi @0, hi_byte(@3)

return:

.ENDMACRO



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                pre-bootloader
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.ORG 0 ;throw in a tiny program as placeholder application code

application_code: ;if we exit the bootloader without uploading anything then this will make us spin instead of executing 32k NOPs and restarting the bootloader
	rjmp application_code


.ORG SMALLBOOTSTART ;place the bootloader at the beginning of the smallest bootloader section (256 words large)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                initialization
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;disable all interrupts so currently bootloaded program can't interrupt bootloading process
	cli

;check if we're loading a program
	cbi DDRB, BTN_IN_PIN ;set the proper pin as input (should be default behavior anyway)
	nop ;must wait one clock cycle for input register to update after setting pins as input
	sbis PINB, BTN_IN_PIN ;if pin is high (button is pressed) then enter the bootloader
	rjmp exit_bootloader ;exit bootloader if button is not pressed

;turn on LED to indicate we're in the bootloader
	sbi DDRB, LED_PIN ;set LED_PIN as output
	sbi PORTB, LED_PIN ;turn LED on

;set up variables for program loading
	clr LAST_BUFFERED_WORD_ADDR_HI ;set instead of clr because it needs to be 0 after the first word is added to the buffer
	clr LAST_BUFFERED_WORD_ADDR_LO ;last word that was put in the page buffer was -2
	clr CURRENT_PAGE_BUFFER_SIZE ;haven't buffered any words yet
	clr PAGE_HAS_BEEN_ERASED ;haven't erased a page yet
	clr DONE_RECEIVING_DATA ;not done receiving data

;init queue to be empty
	ldi HEAD_LO, lo_byte(QUEUE_START) ;place first piece of data at QUEUE_START
	ldi HEAD_HI, hi_byte(QUEUE_START)
	ldi TAIL_LO, lo_byte(QUEUE_START) ;the first address to read data from is QUEUE_START
	ldi TAIL_HI, hi_byte(QUEUE_START)
	clr QUEUE_IS_FULL ;queue aint full

;init USART
	ldi GENERAL_PURPOSE_REG_1, hi_byte(BAUD_BITS)
	sts UBRR0H, GENERAL_PURPOSE_REG_1 ;init baud rate hi
	ldi GENERAL_PURPOSE_REG_1, lo_byte(BAUD_BITS)
	sts UBRR0L, GENERAL_PURPOSE_REG_1 ;init baud rate lo
	ldi GENERAL_PURPOSE_REG_1, 0b00011100 ;turn on both receiver and transmitter, also use 9 bit communication
	sts UCSR0B, GENERAL_PURPOSE_REG_1 ;save USART setting
	ldi GENERAL_PURPOSE_REG_1, 0b00001110 ;9 bit communication mode, 2 stop bits, no parity bit, async USART mode
	sts UCSR0C, GENERAL_PURPOSE_REG_1

;start waiting for first word
	rjmp receive_word 



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                           USART macros and functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: USART_SEND_REG: byte to transmit
send_byte:

wait_for_empty_transmit_buffer:
	lds TEMP_REG, UCSR0A ;can't use sbis on all IO ports, so I have to fill the temp register and do sbrs
	sbrs TEMP_REG, 5 ;check if transmit data register is empty
	rjmp wait_for_empty_transmit_buffer ;if full, keep waiting

;clear 9th bit
	lds TEMP_REG, UCSR0B ;can't use cbi on this IO register
	andi TEMP_REG, 0b11111110 ;always set 9th bit to 0, it's only used when receiving data
	sts UCSR0B, TEMP_REG ;update 9th bit

;send data
	sts UDR0, USART_SEND_REG ;again, can't use OUT instruction because usart registers are above 0x3f

;return
	ret



;args:	0: register in which to save the received byte
;		1: register in which to save the 9th bit of data
.MACRO receive_byte

wait_for_byte:
	lds TEMP_REG, UCSR0A ;grab status reg
	sbrs TEMP_REG, 7 ;see if there is some unread data in USART 
	rjmp wait_for_byte ;if theres no unread data then keep waiting

;make sure there were no errors
	lds USART_SEND_REG, UCSR0A ;load status into USART_SEND_REG so I can send an error asap 
	andi USART_SEND_REG, 0b00011100 ;mask out all bits except errors
	breq read_received_data ;if theres no error we can just read the data 

;throw an error if we have any error bits
	rjmp error ;couldn't just do a brne last instruction because brne can only travel +-64 instructions

read_received_data:
	lds TEMP_REG, UCSR0B ;grab status reg that contains 9th bit of data
	sbrc TEMP_REG, 1 ;check if bit 9 of data is a 1
	ldi @1, 1 ;if bit 9 of data was a 1, record it
	lds @0, UDR0 ;read byte from USART

.ENDMACRO




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                receive a word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

receive_word:

;DELPLS
	ldi USART_SEND_REG, '#'
	rcall send_byte

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
	reset_word_if_equal HEAD_HI, HEAD_LO, QUEUE_END, QUEUE_START



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               request next word
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

try_to_request_next_word:

;check if we're still receiving data
	cpi DONE_RECEIVING_DATA, 1 
	brne start_queue_full_check ;start checking queue if we're not done receiving data

;disconnect from sender and don't try to request another word (we are done receiving data)
	ldi USART_SEND_REG, REQUEST_DISCONNECT
	rcall send_byte ;send request to disconnect
	rjmp check_if_spm_done ;skip the rest of word requesting, start doing spm

start_queue_full_check:
	ldi QUEUE_IS_FULL, 1 ;assume the queue is full by default

;copy head and increase by 2
	movw GENERAL_PURPOSE_REG_1, HEAD_LO ;copy head (movw makes you specify only lo registers)
	adiw GENERAL_PURPOSE_WORD_REG, 2 ;increase by 2

;loop back to 0 if HEAD+2 reaches the end of the queue
	reset_word_if_equal GENERAL_PURPOSE_REG_2, GENERAL_PURPOSE_REG_1, QUEUE_END, QUEUE_START

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
	;an erase can occur when: (buffer is full || (queue is empty && we're done receiving data && theres something in the page buffer))
	;a write can occur when: (erase can occur && erase is done)
	;bootloader must exit when: (queue is empty && we're done receiving data && theres NOTHING in the page buffer)
		;can't just keep track of when we did the final page write because theres a nasty edge condition where the application program size is a multiple of PAGE_LENGTH and then it gets hard to check when the current page write is our last


check_if_spm_done:
	in TEMP_REG, SPMCSR ;load spm status reg
	sbrc TEMP_REG, 0 ;check if spm is still going, skip next instruction if it's not
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

;else if we're not done receiving data then we can't do any spm stuff (have to wait for more data to arrive)
	sbrs DONE_RECEIVING_DATA, 0 ;kind of gross, only using sbrs/rjmp instead of cpi/brne because brne can't jump all the way to receive_word from here
	rjmp receive_word ;restart the main loop

;else if theres some data in the page buffer we need to do one last page erase (since we already know theres no more data coming, we've buffered all we can, and no page erase has occured yet)
	cpi CURRENT_PAGE_BUFFER_SIZE, 0
	brne erase_page ;erase page if buffer isn't empty

;else everything is done, we can exit the bootloader
	rjmp exit_bootloader



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               fill the page buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

fill_page_buffer:

;DELPLS
	ldi USART_SEND_REG, '!'
	rcall send_byte

;dequeue latest word
	ld CURRENT_WORD_HI, TAIL+ ;dequeue first byte and move tail forward
	ld CURRENT_WORD_LO, TAIL+ ;dequeue 2nd byte and move tail forward

;loop tail back to beginning of queue if need be
	reset_word_if_equal TAIL_HI, TAIL_LO, QUEUE_END, QUEUE_START

;add word to page buffer
	in TEMP_REG, SPMCSR ;get spm reg
	ori TEMP_REG, 0b00000001 ;set bit 0 
	out SPMCSR, TEMP_REG ;enable SPM, page buffer fill mode
	spm ;add word to temporary page buffer

;increase word counts
	ldi TEMP_REG, 2 ;we added 1 word (2 bytes)
	add CURRENT_PAGE_BUFFER_SIZE, TEMP_REG ;track the size of the page buffer
	adiw LAST_BUFFERED_WORD_ADDR, 2 ;increase by two because spm wants bit 0 of Z to always be 0 for some reason (so the word count is offset by 1 bit... you can think of this as just counting bytes instead of words)

;DELPLS THIS TOO!!!!
	mov USART_SEND_REG, LAST_BUFFERED_WORD_ADDR_HI
	rcall send_byte
	mov USART_SEND_REG, LAST_BUFFERED_WORD_ADDR_LO
	rcall send_byte

;restart main loop
	rjmp receive_word



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                  erase page
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

erase_page:

;check if we're trying to overwrite the bootloader itself
	ldi GENERAL_PURPOSE_REG_1, lo_byte(ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN)
	cp LAST_BUFFERED_WORD_ADDR_LO, GENERAL_PURPOSE_REG_1 ;compare LAST_BUFFERED_WORD_ADDR and ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN
	ldi GENERAL_PURPOSE_REG_1, hi_byte(ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN)
	cpc LAST_BUFFERED_WORD_ADDR_HI, GENERAL_PURPOSE_REG_1
	
;if we're trying to overwrite the bootloader then throw an error
	ldi USART_SEND_REG, ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR ;prepare error byte for sending
	brsh error ;if LAST_BUFFERED_WORD_ADDR >= ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN then throw the error

;get NEXT_BUFFERED_WORD_ADDR to the proper address for erasing and writing
	sub LAST_BUFFERED_WORD_ADDR_LO, CURRENT_PAGE_BUFFER_SIZE ;subtract to get back to current page (since the NEXT_BUFFERED_WORD_ADDR currently points to the 0th word of the next page)
	sbci LAST_BUFFERED_WORD_ADDR_HI, 0 ;update high byte if need be

;erase the page
	ldi GENERAL_PURPOSE_REG_1, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, GENERAL_PURPOSE_REG_1
	spm ;erase the page

;set a bit so we know the erase command for the current page has gone through
	ldi PAGE_HAS_BEEN_ERASED, 1

;DELPLS
	in USART_SEND_REG, SPMCSR ;load spm status reg
	rcall send_byte
;DELPLS
	ldi USART_SEND_REG, '-'
	rcall send_byte
;DELPLS AGAIN
	mov USART_SEND_REG, LAST_BUFFERED_WORD_ADDR_HI
	rcall send_byte
	mov USART_SEND_REG, LAST_BUFFERED_WORD_ADDR_LO
	rcall send_byte

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

;set NEXT_BUFFERED_WORD_ADDR back to the proper value  
	add LAST_BUFFERED_WORD_ADDR_LO, CURRENT_PAGE_BUFFER_SIZE ;we subtracted PAGE_LENGTH_BYTES when we erased the page, so now lets add them back
	clr TEMP_REG ;theres no add with immedate instruction so I have to use the temp reg
	adc LAST_BUFFERED_WORD_ADDR_HI, TEMP_REG ;add the carry to hi byte

;reset all the variables needed to do another spm
	clr CURRENT_PAGE_BUFFER_SIZE ;page buffer is now 0
	clr PAGE_HAS_BEEN_ERASED ;next page has not yet been erased

;DELPLS
	ldi USART_SEND_REG, '+'
	rcall send_byte
;DELPLS THIS TOO!!!!
	mov USART_SEND_REG, LAST_BUFFERED_WORD_ADDR_HI
	rcall send_byte
	mov USART_SEND_REG, LAST_BUFFERED_WORD_ADDR_LO
	rcall send_byte

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
