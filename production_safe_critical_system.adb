with Ada.Text_IO;    use Ada.Text_IO;
with Ada.Real_Time;  use Ada.Real_Time;
with Ada.Exceptions; use Ada.Exceptions;

procedure Production_Safe_Critical_System is

   ------------------------------------------------------------------
   -- 1. EXCEPTIONS
   ------------------------------------------------------------------

   Invalid_Packet_Error     : exception;
   Illegal_State_Transition : exception;
   Deadline_Exceeded_Error  : exception;
   Queue_Closed_Error       : exception;

   ------------------------------------------------------------------
   -- 2. DATA TYPES
   ------------------------------------------------------------------

   type Byte is mod 256;
   for Byte'Size use 8;

   type Byte_Array is array (Positive range <>) of Byte;

   subtype Packet_ID is Integer range 1 .. 100;
   subtype Payload_Length is Integer range 0 .. 1024;

   type Payload_Array is array (1 .. 1024) of Byte;

   type Parsed_Packet is record
      ID      : Packet_ID := 1;
      Len     : Payload_Length := 0;
      Status  : Byte := 0;
      Payload : Payload_Array := (others => 0);
   end record;

   ------------------------------------------------------------------
   -- 3. STATE MACHINE
   ------------------------------------------------------------------

   type State_Type is
     (Idle, Authenticating, Connected, Terminated);

   function Is_Valid_Transition
     (Current, Target : State_Type) return Boolean
   is
   begin
      case Current is
         when Idle =>
            return Target = Authenticating
              or else Target = Terminated;

         when Authenticating =>
            return Target = Connected
              or else Target = Terminated;

         when Connected =>
            return Target = Connected
              or else Target = Terminated;

         when Terminated =>
            return False;
      end case;
   end Is_Valid_Transition;


   procedure Transition
     (Current : in out State_Type;
      Target  : in State_Type)
   is
   begin
      if not Is_Valid_Transition (Current, Target) then
         raise Illegal_State_Transition
           with "Illegal state transition";
      end if;

      Current := Target;

      Put_Line
        ("[STATE] " & State_Type'Image (Current));
   end Transition;

   ------------------------------------------------------------------
   -- 4. THREAD-SAFE BOUNDED QUEUE
   ------------------------------------------------------------------

   type Packet_Buffer_Array is
     array (Positive range <>) of Parsed_Packet;

   protected type Safe_Queue (Capacity : Positive) is

      entry Enqueue (P : in Parsed_Packet);

      entry Dequeue
        (P         : out Parsed_Packet;
         Available : out Boolean);

      procedure Close;

      function Is_Finished return Boolean;

      function Current_Count return Natural;

   private
      Buffer : Packet_Buffer_Array (1 .. Capacity);

      Head : Positive := 1;
      Tail : Positive := 1;

      Item_Count : Natural := 0;

      Producer_Done : Boolean := False;
   end Safe_Queue;


   protected body Safe_Queue is

      entry Enqueue (P : in Parsed_Packet)
        when Item_Count < Capacity or Producer_Done
      is
      begin
         if Producer_Done then
            raise Queue_Closed_Error
              with "Cannot enqueue into a closed queue";
         end if;

         Buffer (Tail) := P;

         if Tail = Capacity then
            Tail := 1;
         else
            Tail := Tail + 1;
         end if;

         Item_Count := Item_Count + 1;
      end Enqueue;


      entry Dequeue
        (P         : out Parsed_Packet;
         Available : out Boolean)
        when Item_Count > 0 or Producer_Done
      is
      begin
         P :=
           (ID      => 1,
            Len     => 0,
            Status  => 0,
            Payload => (others => 0));

         Available := False;

         if Item_Count > 0 then
            P := Buffer (Head);

            if Head = Capacity then
               Head := 1;
            else
               Head := Head + 1;
            end if;

            Item_Count := Item_Count - 1;
            Available := True;
         end if;
      end Dequeue;


      procedure Close is
      begin
         Producer_Done := True;
      end Close;


      function Is_Finished return Boolean is
      begin
         return Producer_Done and Item_Count = 0;
      end Is_Finished;


      function Current_Count return Natural is
      begin
         return Item_Count;
      end Current_Count;

   end Safe_Queue;


   Task_Queue : Safe_Queue (Capacity => 5);

   ------------------------------------------------------------------
   -- 5. BINARY PACKET PARSER
   --
   -- Header:
   --   Byte 1: Packet ID
   --   Byte 2: Payload length high byte
   --   Byte 3: Payload length low byte
   --   Byte 4: Status
   --   Remaining bytes: Payload
   --
   -- Payload length uses big-endian encoding.
   ------------------------------------------------------------------

   function Parse_Binary_Packet
     (Raw : Byte_Array) return Parsed_Packet
   is
      ID_Value     : Natural;
      Computed_Len : Natural;

      Payload_Data : Payload_Array := (others => 0);

   begin
      ---------------------------------------------------------------
      -- HEADER VALIDATION
      ---------------------------------------------------------------

      if Raw'Length < 4 then
         raise Invalid_Packet_Error
           with "Packet header is shorter than four bytes";
      end if;


      ---------------------------------------------------------------
      -- PACKET ID VALIDATION
      ---------------------------------------------------------------

      ID_Value := Natural (Raw (Raw'First));

      if ID_Value < 1 or else ID_Value > 100 then
         raise Invalid_Packet_Error
           with "Packet ID is outside the permitted range";
      end if;


      ---------------------------------------------------------------
      -- PAYLOAD LENGTH CALCULATION
      ---------------------------------------------------------------

      Computed_Len :=
        Natural (Raw (Raw'First + 1)) * 256
        + Natural (Raw (Raw'First + 2));


      ---------------------------------------------------------------
      -- LENGTH RANGE VALIDATION
      ---------------------------------------------------------------

      if Computed_Len > 1024 then
         raise Invalid_Packet_Error
           with "Payload exceeds the maximum length of 1024 bytes";
      end if;


      ---------------------------------------------------------------
      -- ACTUAL INPUT LENGTH VALIDATION
      ---------------------------------------------------------------

      if Raw'Length /= 4 + Computed_Len then
         raise Invalid_Packet_Error
           with "Declared payload length does not match input size";
      end if;


      ---------------------------------------------------------------
      -- PAYLOAD COPY
      ---------------------------------------------------------------

      for J in 1 .. Computed_Len loop
         Payload_Data (J) :=
           Raw (Raw'First + 3 + J);
      end loop;


      ---------------------------------------------------------------
      -- RETURN VALIDATED PACKET
      ---------------------------------------------------------------

      return
        (ID      => ID_Value,
         Len     => Computed_Len,
         Status  => Raw (Raw'First + 3),
         Payload => Payload_Data);

   end Parse_Binary_Packet;

   ------------------------------------------------------------------
   -- 6. PACKET RECEIVER TASK
   ------------------------------------------------------------------

   task Packet_Receiver;

   task body Packet_Receiver is

      Sample_1 : constant Byte_Array :=
        (1, 0, 3, 200, 10, 20, 30);

      Sample_2 : constant Byte_Array :=
        (2, 0, 2, 200, 40, 50);

      -- Invalid packet: declared payload length is 1535.
      Sample_3 : constant Byte_Array :=
        (3, 5, 255, 200);

      P : Parsed_Packet;

   begin
      ---------------------------------------------------------------
      -- PACKET 1
      ---------------------------------------------------------------

      begin
         P := Parse_Binary_Packet (Sample_1);
         Task_Queue.Enqueue (P);

         Put_Line ("[RECEIVER] Packet 1 accepted");

      exception
         when E : Invalid_Packet_Error =>
            Put_Line
              ("[PACKET 1 ERROR] " & Exception_Message (E));
      end;


      ---------------------------------------------------------------
      -- PACKET 2
      ---------------------------------------------------------------

      begin
         P := Parse_Binary_Packet (Sample_2);
         Task_Queue.Enqueue (P);

         Put_Line ("[RECEIVER] Packet 2 accepted");

      exception
         when E : Invalid_Packet_Error =>
            Put_Line
              ("[PACKET 2 ERROR] " & Exception_Message (E));
      end;


      ---------------------------------------------------------------
      -- PACKET 3: EXPECTED VALIDATION FAILURE
      ---------------------------------------------------------------

      begin
         P := Parse_Binary_Packet (Sample_3);
         Task_Queue.Enqueue (P);

         Put_Line ("[RECEIVER] Packet 3 accepted");

      exception
         when E : Invalid_Packet_Error =>
            Put_Line
              ("[EXPECTED ERROR] " & Exception_Message (E));
      end;


      ---------------------------------------------------------------
      -- NORMAL COMPLETION
      ---------------------------------------------------------------

      Task_Queue.Close;

      Put_Line ("[RECEIVER] Producer finished");

   exception
      ---------------------------------------------------------------
      -- UNEXPECTED PRODUCER FAILURE
      ---------------------------------------------------------------

      when E : others =>
         Task_Queue.Close;

         Put_Line
           ("[RECEIVER FAILURE] " & Exception_Message (E));

   end Packet_Receiver;

   ------------------------------------------------------------------
   -- 7. PROCESSOR TASK
   ------------------------------------------------------------------

   task Processor_Task;

   task body Processor_Task is

      Current_State : State_Type := Idle;

      P : Parsed_Packet;

      Available : Boolean;

      Start_Time : Time;

      Absolute_Deadline : Time;

      Allowed_Window : constant Time_Span :=
        Milliseconds (50);

   begin
      Put_Line ("[PROCESSOR] Started");


      ---------------------------------------------------------------
      -- PROCESS UNTIL THE QUEUE IS CLOSED AND EMPTY
      ---------------------------------------------------------------

      loop
         Task_Queue.Dequeue
           (P         => P,
            Available => Available);

         exit when not Available;


         ------------------------------------------------------------
         -- START PROCESSING TIMER
         ------------------------------------------------------------

         Start_Time := Clock;

         Absolute_Deadline :=
           Start_Time + Allowed_Window;


         ------------------------------------------------------------
         -- PROCESS PACKET
         ------------------------------------------------------------

         begin
            Put_Line
              ("[PROCESSOR] Processing packet ID:" &
               Packet_ID'Image (P.ID));

            declare
               Next_State : State_Type;
            begin
               if P.ID = 1 then
                  Next_State := Authenticating;

               elsif P.ID = 2 then
                  Next_State := Connected;

               elsif Current_State = Connected then
                  Next_State := Connected;

               else
                  raise Illegal_State_Transition
                    with "Packet is invalid in the current state";
               end if;

               Transition
                 (Current => Current_State,
                  Target  => Next_State);
            end;


            ---------------------------------------------------------
            -- DEADLINE CHECK
            ---------------------------------------------------------

            if Clock >= Absolute_Deadline then
               raise Deadline_Exceeded_Error
                 with "Packet processing exceeded 50 milliseconds";
            end if;

            Put_Line
              ("[TIMING] Processing completed within the window");


         exception
            when E : Illegal_State_Transition =>
               Put_Line
                 ("[STATE ERROR] " & Exception_Message (E));

            when E : Deadline_Exceeded_Error =>
               Put_Line
                 ("[DEADLINE ERROR] " & Exception_Message (E));

            when E : others =>
               Put_Line
                 ("[PROCESSING ERROR] " & Exception_Message (E));

         end;

      end loop;


      ---------------------------------------------------------------
      -- CONTROLLED SHUTDOWN
      ---------------------------------------------------------------

      begin
         Transition
           (Current => Current_State,
            Target  => Terminated);

      exception
         when E : Illegal_State_Transition =>
            Put_Line
              ("[SHUTDOWN ERROR] " & Exception_Message (E));
      end;


      Put_Line ("[PROCESSOR] Finished");

   exception
      when E : others =>
         Put_Line
           ("[PROCESSOR FAILURE] " & Exception_Message (E));

   end Processor_Task;

begin
   ------------------------------------------------------------------
   -- 8. MAIN PROCEDURE
   ------------------------------------------------------------------

   Put_Line
     ("==============================================");

   Put_Line
     ("PRODUCTION-SAFE CRITICAL SYSTEM");

   Put_Line
     ("==============================================");

   Put_Line ("[MAIN] System started");

end Production_Safe_Critical_System;

