# Features 
## Slots: gathering input from users

- [Ordering pizza - basic](#ordering-pizza-basic) 
- [Ordering pizza - advanced](#ordering-pizza-advanced)
- [Ordering pizza - multiple values](#ordering-pizza-multiple-values)
- [Ordering pizza - confirmation](#ordering-pizza-confirmation)
- [Ordering pizza - handlers](#ordering-pizza-handlers)
- [Ordering pizza - optional slots](#ordering-pizza-optional-slots)
- [Ordering pizza - free form input](#ordering-pizza-free-form-input)
- [Booking travel - overlapping entities](#booking-travel-overlapping-entities)

###  Ordering pizza - basic <a id="ordering-pizza-basic"></a>

__Description__

[Ordering pizza - basic](pizza-basic.json) is a simple example of slots where a user can order pizza and choose the size and type.

__Features demonstrated__

+ User can provide all information in one sentence:

   - Example: "I'd like to order a small pepperoni pizza"


+ User can provide information by each prompt:

   - Example: "I'd like to order a pizza" 
   
        "What size?" "Small"
        
        "What type?" "Pepperoni"

+ User can provide information by answering a different prompt:

   - Example: "I'd like to order a pizza" 
   
        "What size?" "Pepperoni"
        
        "What type?" "Small"

Additional information: 
- If the slots values are set by entities of a non overlapping types, detecting the response is straight forward. The special case when entity values overlap is addressed by a separate example (see [Booking travel - overlapping entitites](#booking-travel-overlapping-entitites)).
- The node on the right of the slot is executed after completing the slot.
- When execution of the slot is completed (all slots are filled), a summary can be reported, and the result can be stored as part of the responses section of the frame or by following nodes. 
- When the slot is reentered (without clearing the variables), it continues without asking for prefilled values. This might be a desired behavior, if one wants to continue. If one wants to start from scratch, the context variables of the slot should be set to null before reentering the frame
e.g. by setting "context":{"pizza_type":null, "pizza_size":null}

### Ordering pizza - advanced <a id="ordering-pizza-advanced"></a>

__Description__

[Ordering pizza - advanced](pizza-advanced.json) is an example derived from [ordering pizza basic](pizza-basic.json). It is enriched by using advanced options (prompts-advanced) to provide additional responses for users based on input.

__Features demonstrated__

These features can be done by customizing at the slot level.

- Comments/warning: The system can provide comments and warnings with context so reactions can be conditioned on user input. 
    - Example: "$Pizza_type is a good choice, but be warned that the pepperoni is very hot". 

- Slot-specific help handling: You can include an arbitrary condition for each response, therefore responding to selected intents 
    - Example: #Help intent as a condition for Not Found of an individual slot

- Order of handlers: Only one of the prompts will be executed. If you have specific, conditional prompts, they should precede  general ones
    - Example: "$pizza_type is an excellent choice, but be warned that the pepperoni is very hot" should precede "$Pizza_type is an excellent choice".

- "Not found" handling: You can also respond to invalid input in section Not found 
    - Example: If a user does not respond with an appropriate answer, you can prompt again: "You can select one of the following types: margarita, pepperoni, quatro formaggi, mexicana, vegetariana."

- Service side validation: If a response is possible but not in a combination with other responses, you can change the condition and ouput in Customize. To invalidate the slot, you need to go to the json editor and update context, e.g. "context": {"pizza_type":null}
     - Example: "We do not provide small pizza with cheese because our cheese slices are too big." 

###  Ordering Pizza - Multiple Values <a id="ordering-pizza-multiple-values"></a>

__Description__

[Ordering pizza - multiple values](pizza-toppings-basic.json) is a basic example of using slots with multiple values. The user can provide an arbitrary number of toppings.

__Features demonstrated__

Slots variable can be a simple type of an array.

- Putting an array of entities in context: To copy the whole array, one needs to add .values. Referring by just the name will return only the first element.
     - Example: $pizza_toppings=@pizza_toppings.values returns all elements 
     - Example: $pizza_toppings=@pizza_toppings returns just the first element of @pizza_toppings

- Outputting the array: The expression language (SpEL) does not support loops to iterate over the indexes of an array. Instead, one needs to use operations that handles the whole array to print out all the values.
     - Example: <? $pizza_toppings.join(', ') ?>

- Referring to the number of elements of the entity: Note that operations @pizza_toppings.length differs syntactically for an array in context
     - Example: $pizza_toppings.size()

Additional information:
- It is good practice to have the bot confirm what was understood. Note however, that the prompts are also rendered when filling in within a single sentence, which may not be desired for some applications.
     - Example: "I want to order large Margarita with olives"

         "Size of the pizza ordered is large." "Type of the pizza order is set to Margarita." "Extra topping: olives" "Thank you for ordering a large margarita pizza with olives."
         
###  Ordering pizza - confirmation <a id="ordering-pizza-confirmation"></a>

__Description__

[Ordering pizza - confirmation](pizza-confirm.json) is an example demonstrating a confirmation at the end of ordering a pizza. A separate slot (pizza_confirmed) is introduced as the last slot of the node. The prompt summarizes the values filled so far and requests confirmation before leaving the node. User can correct previously filled slots, confirm that all slots are correct or cancel and leave slot without performing an action.

__Features demonstrated__

- Block confirmation and correction authoring patterns
- Next step confirmation: Child node makes decision on what to do with content. It gets the $pizza_confirmed flag indicating if the values are valid and if the following action should follow.
- Confirmed/canceled: The slot values are set to null to permit entering the frame again with empty values.

Additional Information:
- Currently, we do not have a mechanism for leaving frame prematurely (prior to filling all the slots), this will change soon.
- If the slot is set to the value which it had before, it is not considered to be a slot change. Therefore, no match handler can be called even if the value provided in a sentence is a valid value of some slot.

__Internal comment__

Check exiting the frame mechanism it might change before releasing. 

###  Ordering pizza - handlers <a id="ordering-pizza-handlers"></a>

__Description__

[Ordering pizza - handlers](pizza-handler.json) is an example demonstrating how general slot handlers can be used if a user's input are not specific to a particular slot or do not provide a value for any other slots. The general slot handlers check if the slot conditions and match handlers are not triggered. If none of the general slot handlers match, the specific slot "No match" handler is checked. The handlers can be found under "Manage handler." The example is derived from pizza_confirm.json.

__Features demonstrated__

- General slot handler with #help as condition: One does not need to add help processing at each individual slot but can provide a shared handler for the whole node
- Global handling of the node related operations 
     - Example: #leave_frame (premature leaving the frame)  
     - Example: #reset_frame (setting all the slot values to null).
- Specific slot "Match" handlers and slot conditions are checked with precedence: If an entity triggers, corresponding to pizza_confirm, the general slot level handler #exit does not match. This might be a problem when using the same wording for the condition pizza_confirm slot and for the general slot level #exit. To avoid this, one can rely on general slot handler entirely to exit prematuraly from the node and not provide the option for pizza_confirm.

### Ordering pizza - optional slots <a id="ordering-pizza-optional-slots"></a>

__Description__

[Ordering pizza - optional slots](pizza-optional.json) is an example demonstrating an optional slot feature. An optional slot (pizza_place) collects information on how the user wants to package the order "to stay" or "to go" but does not prompt for this input.

__Features demonstrated__

- Empty prompt: Optional slot is the slot without text in the prompt
- No prompt to user: User is not asked for the value of the slot. If the user does not fill in the slot, there is no reminder to be populated.
- Prompt can be filled: User can provide the value of the optional slot at any moment of processing the node. The value is then populated.
     - Example: "I want to order a Margarita to go"
- Node interaction completes if all compulsory slots are filled (disregarding the optional slot values).

### Ordering pizza - free form input <a id="ordering-pizza-free-form-input"></a>

__Description__

[Ordering pizza - free form input](pizza-take-what-you-get.json) is a pizza-basic.json example augmented with a slot collecting the pizza delivery address. The address is taken in free form, without any restriction for format of the input.

__Features demonstrated__

- Different slot condition: Setting slot value with a non entity
     - Example: Setting "Check for" value in slot as !#order&&!@pizza_size&&!@pizza_type.

Additional information:
- When collecting any input, this can be input.text (or even true as input.text is always true). The problem is that input.text accepts any input, even the phrase used for entering the frame e.g. "I want to order pizza". It would match the free form slot and user would not be ever asked for an address.  We can partially avoid the problem by excluding sentences matching the other slots.
- One also has to assign a value to context variable represented by the slot (pizza_address). This is typically done automatically (as the value of entity is assigned to slot variable by default). In our case we must do it manually. It can be done by going to the three dot menu next to "Save it as" and by replacing “!#order&&!@pizza_size&&!@pizza_type”  by ”<?input.text?> ”.
- Note, that any change in slot's "Check for" input line will override this change so you need to remember to change it back. This is just a partial solution to the problem. If one enters input for other slots which has a spelling mistake, it will not be accepted by the slot but will be happily taken by our greedy input.text slot. Then the user will not be asked for the value of address any more which is bad behavior. Depending on the input, one could condition the free form slot on an entity which would be detecting the particular type of input.
- The more reliable way so far for collecting free form input is to use data collection without using the frames. But this will probably change soon.
 
__Internal comment__

This will change by introduction of the slot scope (enforcing that the slot is filled only when it gets focus). 

###  Booking Travel - overlapping entities <a id="booking-travel-overlapping-entities"></a>

__Description__

[Booking Travel - overlapping entitites](travel-overlap.json) is an example of a user booking travel to X city from Y city. This demonstrates the processing of multiple slots associated with the overlapping entities. The user should provide origin, destination and date of a travel. The form contains two slots associated with the same entity @sys_location (travel_from and travel_to) and one slot filled by unique entity @sys_date (travel_date). The last one is the confirmation slot travel_confirm using the concept of confirmation described in pizza_confirm.json.

__Features demonstrated__

- User provides information by prompt:
    - Example: "Book travel ticket"
    
         "Where do you want to travel from?" "From Prague"
           
         "Where do you want to travel to?" "London tomorrow"
           
         "I understand that you want to travel from Prague to London on 2017-06-07. Is that correct?"
           
Additional Information:
- It gets more tricky if slots are filled by the two entities of the same type. The system has no contextual information, so it will only use the first entity with the information provided. The first slot will be filled and the second slot will be prompted. 
    - Example: "Book travel ticket"
    
         "Where do you want to travel from?" "From Prague to London tomorrow"
           
         "Where do you want to travel to?" "London"
           
         "I understand that you want to travel from Prague to London on 2017-06-07. Is that correct?"
- Please note, if the user provides the input in the wrong order, e.g. "To London from Prague tomorrow", the value is not assigned correctly as the first entity is London and is assigned to first slot (travel_from). 
- One could also check if more entities of the same type are present and act accordingly (ask for disambiguation, look for extra clues like "from" and "to").
- If two entities of a different type are detected, they are processed correctly (in example above travel_date and travel_from).
- The same problem will appear when two slots are filled by entities which have overlapping values.

__Internal comment__

Check this before the release please, we might get change of the behavior, e.g. use entities in order of slots. 
