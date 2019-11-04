;before uploading the bootloader the following fuses must be changed:
	;BOOTRST must be *programmed* (set to 0)
		;this fuse determines if the mcu begins exectution in the bootloader section instead of address 0
	;BOOTSZ1 and BOOTSZ0 must be *unprogrammed* (set to 1)
		;these two fuses control WHERE the bootloader section begins in memory
		;setting them both to 1 creates the smallest bootloader space possible on the 328p (256 words)

;it is recommended to also set up the following lock bits after the bootloader is uploaded to stop application code from erasing the bootloader:
	;*program* BLB11 (set to 0) and *unprogram* BLB12 (set to 1)
		;this will make it impossible for any code to write to the bootloader section 


;go to page 277 in atmega datasheet to read about "programming the flash"
;go to page 287 in datasheet for "Assembly Code Example for a Boot Loader"

;flash must be addressed in the Z register using pages and words
;a word is 2 bytes long, there are 64 words per page
;there are 256 pages
;when using Z to address a page, bits 14:7 specify a page and bits 6:1 specifify a word within that page
;   R31     R30
;xppppppp pwwwwwwx 

;you can only write to the flash one page at a time
;first fill the page buffer, then erase the old page, then write the new page.


;MAKE SURE YOU'RE READING AND WRITING TO THE RIGHT PINS
;BEFORE RESETTING THE USART MAKE SURE ALL SENDING HAS FINISHED (DIFFERENT FROM WHEN YOU'RE ABLE TO WRITE TO TRANSMITTER)
	;AHHHHH NOTHING WORKS FOR SOME REASON.... I DONT REALLY NEED TO BE ABLE TO DO IT EXCEPT FOR DEBUG THOUGH....
	;WHEN CONSIDERING ALL THE OPTIONS THE BEST ONE TBH IS JUST SENDING 3 BYTES TO FLUSH THE CHUBES

;WOULD IT BE FASTER TO FILL PAGE BUFFER ITSELF INSTEAD OF QUEUE EVEN THOUGH IT MEANS MORE OS CALLS?
	;could run some speed tests on a bunch of things, could also just ignore it since it doesnt totally matter
;STILL SHOULD DO A READ OF THE WHOLE THING TO MAKE SURE EVERYTHING MAKES SENSE AND THERES NO USELESS VARIABLES
;THERES PROBABLY NEW VARIABLES THAT YOU USE IN YOUR CODE THAT YOU DONT HAVE DEFINED 
	;although I guess compiling will tell you all about em
;KEEP IN MIND THAT WE'RE OFTEN GONNA BOOTLOAD A TRASH BYTE AT THE END (if theres an odd number of bytes bootloaded)
	;often not 0
;MIGHT WANNA FIGURE OUT IF I CAN ADD THINGS TO THE PAGE BUFFER WHILE A PAGE ERASE IS HAPPENING
;STILL HAVE TO CHANGE BOOTLOADER OVERRIDE CHECK TO WRITE FINAL PAGE



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                 definitions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;gpio pins
.EQU BTN_IN_PIN = 1 ;pin that bootloader button is on
.EQU LED_PIN = 0 ;pin that the general purpose LED is on

;USART definitions and transmission bytes
.EQU REQUEST_NEW_DATA = 'w' ;asks sender for next chunk of data
.EQU DONE_BOOTLOADING = 'd' ;tells sender that we've bootloaded the whole program
.EQU ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR = 'o' ;tells sender that the program that is being bootloaded is too long, or the bootloader messed up and tried to overwrite it's own memory
.EQU BAUD_RATE = 38400 ;target baud rate
.EQU OSC_FREQ = 16000000 ;clock rate of mcu
.EQU BAUD_BITS = (OSC_FREQ / BAUD_RATE / 16) - 1 ;the actual bits that must be writted to the baud rate registers
#define USART_SEND_REG R20

;definitions for writing to flash
.EQU PAGE_LENGTH = 64 ;length of a page in words
.EQU ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN = SMALLBOOTSTART * 2 ;bootloader is not allowed to write to this address or beyond (or else it would destroy it's own code), also * 2 because it's specified in bytes instead of words (since that's how we address data when writing it to flash)

#define NEXT_BUFFERED_WORD_ADDR Z ;address to place the next word (address must be in BYTES instead of words)
#define NEXT_BUFFERED_WORD_ADDR_LO R30
#define NEXT_BUFFERED_WORD_ADDR_HI R31

#define TEMP_NEXT_BUFFERED_WORD_ADDR_LO R24 ;using R24 and R25 because they're the only non X/Y/Z registers that can be used with an ADIW instruction
#define TEMP_NEXT_BUFFERED_WORD_ADDR_HI R25 ;these 2 regs are for storing any random values
#define TEMP_NEXT_BUFFERED_WORD_ADDR TEMP_NEXT_BUFFERED_WORD_ADDR_HI: TEMP_NEXT_BUFFERED_WORD_ADDR_LO

#define CURRENT_WORD_LO R0 ;when adding a word to the page buffer we have to address it using R1:R0 
#define CURRENT_WORD_HI R1

#define BUFFER_LOOP_COUNTER R16 ;used to count how many words we have to stick into the temporary page buffer

;queue definitions
.EQU PAGE_LENGTH_BYTES = PAGE_LENGTH * 2
.EQU QUEUE_SIZE_PAGES = 15 ;the size of the queue in pages (the entire ram is actually 16 pages long BUT we need to save some of the ram for the stack)
.EQU QUEUE_SIZE_BYTES = PAGE_LENGTH_BYTES * QUEUE_SIZE_PAGES ;size of the queue in bytes
.EQU QUEUE_START = 0x100 ;sram only actually starts at 0x100, before that is memory mapped stuff
.EQU QUEUE_END = QUEUE_START + QUEUE_SIZE_BYTES ;turns out I dont actually need to use this in the code but... good to keep in mind still

#define QUEUE_HEAD X ;head of circular queue (address in sram to place the next word of data)
#define QUEUE_HEAD_LO R26
#define QUEUE_HEAD_HI R27

#define QUEUE_TAIL Y ;tail of queue (address in sram to find next queued word)
#define QUEUE_TAIL_LO R28
#define QUEUE_TAIL_HI R29

;other register definitions
#define DONE_RECEIVING_DATA R18 ;stores a 1 if we're done receiving data, 0 otherwise
#define TEMP_REG R21 ;used for storing values that will be used very soon, ie in an instruction or 2. I should always be able to easily know if this register is available or not just by glancing at nearby instructions



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                   macros
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: word: word to find lo byte of
;return: lo byte of arg 1
#define lo_byte(word) (word & 0xFF)

;args: word: word to find hi byte of
;return: hi byte of input
#define hi_byte(word) (word >> 8)


;waits for an spm instruction to finish executing
.MACRO wait_spm
check_if_spm_done:
	in TEMP_REG, SPMCSR ;load spm status reg
	sbrc TEMP_REG, 0 ;check if spm is still going, skip next instruction if it's not
	rjmp check_if_spm_done ;keep waiting for spm to finish
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
	clr NEXT_BUFFERED_WORD_ADDR_HI ;start buffering words at address 0
	clr NEXT_BUFFERED_WORD_ADDR_LO 
	clr DONE_RECEIVING_DATA ;not done receiving data

;init queue to be empty
	ldi QUEUE_HEAD_LO, lo_byte(QUEUE_START) ;place first piece of data at QUEUE_START
	ldi QUEUE_HEAD_HI, hi_byte(QUEUE_START)
	ldi QUEUE_TAIL_LO, lo_byte(QUEUE_START) ;the first address to read data from is QUEUE_START
	ldi QUEUE_TAIL_HI, hi_byte(QUEUE_START)

;init USART
	ldi TEMP_REG, hi_byte(BAUD_BITS)
	sts UBRR0H, TEMP_REG ;init baud rate hi
	ldi TEMP_REG, lo_byte(BAUD_BITS)
	sts UBRR0L, TEMP_REG ;init baud rate lo
	ldi TEMP_REG, 0b00011100 ;turn on both receiver and transmitter, also use 9 bit communication
	sts UCSR0B, TEMP_REG ;save USART setting
	ldi TEMP_REG, 0b00001110 ;9 bit communication mode, 2 stop bits, no parity bit, async USART mode
	sts UCSR0C, TEMP_REG



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                receive data
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

receive_data:

;let upload script know we're ready to receive more data
	ldi USART_SEND_REG, REQUEST_NEW_DATA
	rcall send_byte

;reset queue to start
	ldi QUEUE_HEAD_LO, lo_byte(QUEUE_START)
	ldi QUEUE_HEAD_HI, hi_byte(QUEUE_START) ;queue doesn't start at 0 because memory mapped registers

fill_queue:

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
	ldi DONE_RECEIVING_DATA, 1 ;if bit 9 of data was a 1, record it
	lds TEMP_REG, UDR0 ;read byte from USART
	st QUEUE_HEAD+, TEMP_REG ;store received byte in queue and move the head forward

;stop receiving if we got the last byte
	cpi DONE_RECEIVING_DATA, 1
	breq process_received_data ;process data when flag indicates that theres no more data coming

;keep receiving data while the queue isn't full
	cpi QUEUE_HEAD_LO, lo_byte(QUEUE_END) ;start 16 bit compare with QUEUE_HEAD and QUEUE_SIZE
	ldi TEMP_REG, hi_byte(QUEUE_END) ;load hi byte into temp reg because I cant do a cpc with an immediate
	cpc QUEUE_HEAD_HI, TEMP_REG ;finish comparing
	brlo fill_queue ;queue isnt full if QUEUE_HEAD < QUEUE_SIZE



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                               fill the page buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

process_received_data:

;reset position we're reading queue from
	ldi QUEUE_TAIL_LO, lo_byte(QUEUE_START)
	ldi QUEUE_TAIL_HI, hi_byte(QUEUE_START) ;queue doesn't start at 0 because memory mapped registers

buffer_next_page:

;reset loop counter
	ldi BUFFER_LOOP_COUNTER, PAGE_LENGTH ;going to buffer 64 words

buffer_next_word:

;load data needed to buffer the next word
	ld CURRENT_WORD_HI, QUEUE_TAIL+ ;dequeue first byte and move tail forward
	ld CURRENT_WORD_LO, QUEUE_TAIL+ ;dequeue 2nd byte

;add word to page buffer
	in TEMP_REG, SPMCSR ;get spm reg
	sbr TEMP_REG, 0b00000001 ;set bit 0 
	out SPMCSR, TEMP_REG ;enable SPM, page buffer fill mode
	spm ;add word to temporary page buffer

;update byte counts
	adiw NEXT_BUFFERED_WORD_ADDR, 2 ;increase by two because spm wants bit 0 of Z to always be 0 for some reason (so the word count is offset by 1 bit... you can think of this as just counting bytes instead of words)
	subi BUFFER_LOOP_COUNTER, 1 

;if the whole page has been buffered it's time to write it
	breq write_page ;branch if BUFFER_LOOP_COUNTER is 0

;else, keep looping if we haven't buffered everything in the queue
	cp QUEUE_TAIL_LO, QUEUE_HEAD_LO ;16 bit compare of QUEUE_TAIL and QUEUE_HEAD
	cpc QUEUE_TAIL_HI, QUEUE_HEAD_HI
	brlo buffer_next_word ;if QUEUE_TAIL < QUEUE_HEAD then keep buffering



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                   write page
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

write_page:

;prepare NEXT_BUFFERED_WORD_ADDR for erase and write operations
	movw TEMP_NEXT_BUFFERED_WORD_ADDR_LO, NEXT_BUFFERED_WORD_ADDR_LO ;save NEXT_BUFFERED_WORD_ADDR so it can be restored later (movw makes you specify only lo registers)
	sbiw NEXT_BUFFERED_WORD_ADDR, 1 ;wanna lower NEXT_BUFFERED_WORD_ADDR back to the last multiple of 64, have to sub 1 because if we buffered a whole page then NEXT_BUFFERED_WORD_ADDR is already pointing to the 0th word of the NEXT page (this will always work because we always buffer at least one word)
	andi NEXT_BUFFERED_WORD_ADDR_LO, 0b11000000 ;and lo byte with a bit mask to round back to last 64 bits

;check if we're trying to overwrite the bootloader itself
	ldi TEMP_REG, lo_byte(ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN)
	cp NEXT_BUFFERED_WORD_ADDR_LO, TEMP_REG ;compare NEXT_BUFFERED_WORD_ADDR and ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN
	ldi TEMP_REG, hi_byte(ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN)
	cpc NEXT_BUFFERED_WORD_ADDR_HI, TEMP_REG
	
;if we're trying to overwrite the bootloader then throw an error
	ldi USART_SEND_REG, ATTEMPT_TO_OVERWRITE_BOOTLOADER_ERROR ;prepare error byte for sending
	brsh error ;if NEXT_BUFFERED_WORD_ADDR >= ILLEGAL_BUFFERED_WORD_ADDRS_BEGIN then throw the error

;erase the page indicated by NEXT_BUFFERED_WORD_ADDR
	ldi TEMP_REG, 0b00000011 ;Enable SPM, page erase mode
	out SPMCSR, TEMP_REG
	spm ;erase the page
	wait_spm ;wait for erase to finish

;write the current page indicated by NEXT_BUFFERED_WORD_ADDR
	ldi TEMP_REG, 0b00000101 ;enable SPM, write mode
	out SPMCSR, TEMP_REG
	spm ;write the page
	wait_spm ;wait for write to finish

;restore NEXT_BUFFERED_WORD_ADDR to the proper value (can't just add 64 because we're gonna use this value to keep track of how much program memory to send back to upload script later)
	movw NEXT_BUFFERED_WORD_ADDR_LO, TEMP_NEXT_BUFFERED_WORD_ADDR_LO ;(movw makes you specify only lo registers)

;if we haven't written all the pages in the queue, keep writing
	cp QUEUE_TAIL_LO, QUEUE_HEAD_LO ;16 bit compare of QUEUE_TAIL and QUEUE_HEAD
	cpc QUEUE_TAIL_HI, QUEUE_HEAD_HI
	brlo buffer_next_page ;if QUEUE_TAIL < QUEUE_HEAD then keep buffering

;if we haven't got all the data yet, receive some more
	sbrs DONE_RECEIVING_DATA, 0 ;using sbrs instead of cpi because receive_data is too far away for a branch instruction
	rjmp receive_data

;else, we're done writing all the data (all pages have been written and no more data is coming)
	ldi USART_SEND_REG, DONE_BOOTLOADING ;tell upload script that the whole program has been bootloaded
	rcall send_byte


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                 reset registers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;enable execution of application code
	ldi TEMP_REG, 0b00010001 ;running this spm instruction reenables the RWW (read while write) section of the flash memory
	out SPMCSR, TEMP_REG ;I need to reenable the RWW section because it gets disabled automatically whenever you do any writing or erasing to that section
	spm

;reset gpio registers
	clr TEMP_REG ;next two registers should be reset to 0
	out PORTB, TEMP_REG ;reset port b but also turn off LED to indicate we're no longer in the bootloader
	out DDRB, TEMP_REG ;all port b pins are inputs by default

wait_for_final_usart_transmit:
	lds TEMP_REG, UCSR0A ;have to wait for any transmissions to finish before I reset the usart, otherwise some data could be lost
	sbrs TEMP_REG, 6 ;check if theres any data being sent still
	rjmp wait_for_final_usart_transmit ;keep waiting until transmission is done

;flush out untransmitted usart data
	ser USART_SEND_REG
	rcall send_byte ;I shouldn't have to do this because I already check bit 6 of UCSR0A but for some reason it doesn't work (possible pyserial issue?)
	rcall send_byte 
	rcall send_byte ;send thrice just so it doesn't reset before the first one is sent, you'll still just see 1 '\xFF' probably

;reset usart registers
	clr TEMP_REG ;next three registers should be reset to 0
	sts UCSR0B, TEMP_REG ;clear status reg B
	sts UBRR0L, TEMP_REG ;clear baud rate
	sts UBRR0H, TEMP_REG
	ldi TEMP_REG, 0b00000110 ;default behaviour is async, no parity, 1 stop bit, 8 data bits
	sts UCSR0C, TEMP_REG ;set status reg C to default
	ldi TEMP_REG, 0b00100000 ;default behaviour is no multiprocessor comm mode, 1x usart transmission speed
	sts UCSR0A, TEMP_REG ;set status reg A to default



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                exit bootloader
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

exit_bootloader: ;clean exit
	jmp 0 ;start uploaded program


error: ;reports the byte in USART_SEND_REG back to sender then spins forever
	rcall send_byte
panic_forever: ;infinite loop
	rjmp panic_forever





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                  functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;args: USART_SEND_REG: byte to transmit
send_byte:

wait_for_empty_transmit_buffer:
	lds TEMP_REG, UCSR0A ;can't use sbis on all IO ports, so I have to fill the temp register and do sbrs
	sbrs TEMP_REG, 5 ;check if transmit data register is empty
	rjmp wait_for_empty_transmit_buffer ;if full, keep waiting

;clear 9th bit
	lds TEMP_REG, UCSR0B ;can't use cbi on this IO register
	cbr TEMP_REG, 0b00000001 ;always set 9th bit to 0, it's only used when receiving data (cbr clears the specified bits)
	sts UCSR0B, TEMP_REG ;update 9th bit

;send data
	sts UDR0, USART_SEND_REG ;again, can't use OUT instruction because usart registers are above 0x3f

;return
	ret