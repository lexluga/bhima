
DELIMITER $$

DROP PROCEDURE IF EXISTS `UpdateStaffingIndices`$$
CREATE   PROCEDURE `UpdateStaffingIndices`(IN _dateFrom DATE, IN _dateTo DATE)
BEGIN
	DECLARE _id mediumint(8) unsigned;
	DECLARE _date_embauche DATE;
	DECLARE _employee_uuid, _grade_uuid, _current_staffing_indice_uuid, _last_staffing_indice_uuid BINARY(16);
	DECLARE _hiring_year, _fonction_id INT;
	DECLARE _grade_indice, _last_grade_indice, _function_indice DECIMAL(19,4);

	DECLARE done BOOLEAN;
	DECLARE curs1 CURSOR FOR 
	SELECT uuid, grade_uuid, fonction_id, date_embauche
		FROM employee;

	DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

	OPEN curs1;
		read_loop: LOOP
		FETCH curs1 INTO _employee_uuid, _grade_uuid, _fonction_id, _date_embauche;
			IF done THEN
				LEAVE read_loop;
			END IF;
			-- anciennette
			SET _hiring_year = FLOOR(DATEDIFF(_dateTo, _date_embauche)/365);
			-- is there any staffing indice specified for the employee in this payroll config period interval ?
			-- _current_staffing_indice_uuid is the indice for this payroll config period interval
			SET _current_staffing_indice_uuid  = IFNULL((
				SELECT st.uuid
				FROM staffing_indice st
				WHERE st.employee_uuid = _employee_uuid AND (st.date BETWEEN _dateFrom AND _dateTo)
				LIMIT 1
			), HUID('0'));

			SET _last_staffing_indice_uuid  = IFNULL((
				SELECT st.uuid
				FROM staffing_indice st
				WHERE st.employee_uuid = _employee_uuid
				ORDER BY st.created_at DESC
				LIMIT 1
			), HUID('0'));

			SET @grade_indice_rate = 0.05;
			SET @shouldInsert = FALSE;
			
			-- check if the date_embauche is in the current payroll config period interval
			SET @hiring_date = DATE(CONCAT(YEAR(_dateTo), '-', MONTH(_date_embauche), '-', DAY(_date_embauche)));
			SET @date_embauche_interval = (@hiring_date BETWEEN _dateFrom AND _dateTo);
			
			-- should update staffing_indice and there's no previous staffing_indice for in this payroll config period interval
			IF  ((@date_embauche_interval=1)  AND (_current_staffing_indice_uuid = HUID('0'))) THEN
				-- increase the _last_grade_indice if it exist
				IF (_last_staffing_indice_uuid <> HUID('0')) THEN
					SET _last_grade_indice = (SELECT grade_indice FROM staffing_indice WHERE uuid = _last_staffing_indice_uuid);
					SET _grade_indice =  _last_grade_indice + (_last_grade_indice*@grade_indice_rate);
				ELSE
					SET _grade_indice = (SELECT IFNULL(value, 0)  FROM staffing_grade_indice WHERE grade_uuid = _grade_uuid LIMIT 1);
					SET _grade_indice = _grade_indice + (_grade_indice*_hiring_year*@grade_indice_rate);
				END IF;
				SET @shouldInsert = TRUE;
			
			-- no indice has been created for the employee previously(no record in the table for him)
			-- this is used when configuring for the first time
			ELSE
			 	IF ((@date_embauche_interval = 0) && (_last_staffing_indice_uuid = HUID('0'))) THEN
					SET _grade_indice = (SELECT IFNULL(value, 0)  FROM staffing_grade_indice WHERE grade_uuid = _grade_uuid LIMIT 1);
					SET _grade_indice = _grade_indice + (_grade_indice * _hiring_year * @grade_indice_rate);
					SET @shouldInsert = TRUE;
				END IF;
			END IF;

			IF @shouldInsert THEN
				SET _function_indice = (SELECT IFNULL(value, 0) FROM staffing_function_indice WHERE fonction_id = _fonction_id LIMIT 1);			
				INSERT INTO staffing_indice(uuid, employee_uuid, grade_uuid, fonction_id, grade_indice, function_indice, date)
				VALUES(HUID(uuid()), _employee_uuid,  _grade_uuid , _fonction_id, IFNULL(_grade_indice, 0), IFNULL(_function_indice, 0), _dateTo);
			END IF;
		END LOOP;
	CLOSE curs1;
END$$

DROP FUNCTION IF EXISTS `maxBaseIndice`$$
CREATE  FUNCTION `maxBaseIndice`(
	_payroll_configuration_id INT
) RETURNS DECIMAL(19, 4) DETERMINISTIC
BEGIN
	DECLARE _dateFrom, _dateTo DATE;
	SELECT dateFrom, dateTo INTO _dateFrom, _dateTo
	FROM payroll_configuration
	WHERE id = _payroll_configuration_id;

	RETURN (
		SELECT IFNULL(MAX(st.grade_indice), 0)
		FROM staffing_indice st WHERE  (st.date BETWEEN _dateFrom  AND _dateTo)
	);

END$$

DROP FUNCTION IF EXISTS `sumBaseIndice`$$
CREATE  FUNCTION `sumBaseIndice`(_payroll_configuration_id INT) RETURNS DECIMAL(19, 4) DETERMINISTIC
BEGIN

	DECLARE _employee_uuid BINARY(16);
	DECLARE _employee_grade_indice, totals DECIMAL(19, 4);
	
	DECLARE done BOOLEAN;
	DECLARE curs1 CURSOR FOR 
	SELECT cei.employee_uuid 
	FROM payroll_configuration pc
	JOIN config_employee ce ON ce.id = pc.config_employee_id
	JOIN config_employee_item cei ON cei.config_employee_id = ce.id
	WHERE pc.id = _payroll_configuration_id;

	DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

	SET totals = 0;
	
	OPEN curs1;
		read_loop: LOOP
		FETCH curs1 INTO _employee_uuid;
			IF done THEN
				LEAVE read_loop;
			END IF;
			SET _employee_grade_indice  = (
				SELECT st.grade_indice
				FROM staffing_indice st
				WHERE st.employee_uuid = _employee_uuid
				ORDER BY st.created_at DESC
				LIMIT 1
			);
			SET totals = totals + IFNULL(_employee_grade_indice, 0);
		
		END LOOP;
	CLOSE curs1;
	RETURN totals;
END$$

DROP FUNCTION IF EXISTS `getStagePaymentIndice`$$
CREATE  FUNCTION `getStagePaymentIndice`(_employee_uuid BINARY(16), 
_payroll_configuration_id INT, _rubric_abbr VARCHAR(50) ) RETURNS DECIMAL(19, 4) DETERMINISTIC
BEGIN
	return IFNULL((SELECT rubric_value
		FROM stage_payment_indice sp
		JOIN rubric_payroll r ON r.id = sp.rubric_id
		WHERE sp.employee_uuid = _employee_uuid AND r.abbr = _rubric_abbr AND	
			payroll_configuration_id = _payroll_configuration_id
		LIMIT 1), 0);
END;


DROP PROCEDURE IF EXISTS `addStagePaymentIndice`$$
CREATE   PROCEDURE `addStagePaymentIndice`( 
	IN _employee_uuid BINARY(16),IN _payroll_configuration_id INT(10),

	IN _rubric_abbr VARCHAR(50), IN _value DECIMAL(19, 10)
)
BEGIN
   DECLARE _rubric_id INT;
   DECLARE _stage_payment_uuid BINARY(16);

   SELECT id INTO _rubric_id FROM rubric_payroll WHERE abbr = _rubric_abbr;
 	
   IF _rubric_id > 0 THEN 
	SET _stage_payment_uuid = IFNULL((
		SELECT sp.uuid 
		FROM stage_payment_indice sp
		JOIN rubric_payroll r ON r.id = sp.rubric_id
		WHERE sp.employee_uuid = _employee_uuid AND r.abbr = _rubric_abbr AND	
			payroll_configuration_id = _payroll_configuration_id
		LIMIT 1), HUID('0')
	);
   IF _stage_payment_uuid <> HUID('0') THEN
	DELETE FROM stage_payment_indice  WHERE uuid = _stage_payment_uuid;
   END IF;

   INSERT INTO stage_payment_indice
   	(uuid,employee_uuid, payroll_configuration_id, rubric_id, rubric_value ) VALUES
    (HUID(uuid()), _employee_uuid, _payroll_configuration_id, _rubric_id, _value);
  END IF;
END $$


DROP PROCEDURE IF EXISTS `updateIndices`$$
CREATE   PROCEDURE `updateIndices`( IN _payroll_configuration_id INT)
BEGIN

	DECLARE _employee_uuid BINARY(16);
	DECLARE _employee_grade_indice, _sumBaseIndice,  _function_indice DECIMAL(19, 4);
	
	DECLARE done BOOLEAN;
	DECLARE curs1 CURSOR FOR 
	SELECT cei.employee_uuid 
	FROM payroll_configuration pc
	JOIN config_employee ce ON ce.id = pc.config_employee_id
	JOIN config_employee_item cei ON cei.config_employee_id = ce.id
	WHERE pc.id = _payroll_configuration_id;

	DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
	
	OPEN curs1;
		read_loop: LOOP
		FETCH curs1 INTO _employee_uuid;
			IF done THEN
				LEAVE read_loop;
			END IF;

			SELECT st.grade_indice, st.function_indice
			INTO _employee_grade_indice, _function_indice
			FROM staffing_indice st
			WHERE st.employee_uuid = _employee_uuid
			ORDER BY st.created_at DESC
			LIMIT 1;
						
			CALL addStagePaymentIndice( _employee_uuid,_payroll_configuration_id,'indice de base', IFNULL(_employee_grade_indice, 0));
			
			SET @responsabilite = IFNULL(_function_indice, 0);
			CALL addStagePaymentIndice( _employee_uuid,_payroll_configuration_id,'responsabilité', @responsabilite);
									
			-- tot jrs
			SET @tot_jrs = getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'Jrs prestes') +
				 getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'jrs suppl');

			CALL addStagePaymentIndice( _employee_uuid,_payroll_configuration_id,'tot jrs', IFNULL(@tot_jrs, 0));
			
			-- 
			SET @nbrJour = 0;
			SET @envelopPaie = 0;
			-- get pay_envelope from staffing_indice_parameters table
			SELECT IFNULL(pay_envelope, 0), IFNULL(working_days, 0) 
			INTO @envelopPaie, @nbrJour 
			FROM staffing_indice_parameters
			WHERE payroll_configuration_id = _payroll_configuration_id;
			
			-- base indice
			SET _sumBaseIndice = sumBaseIndice(_payroll_configuration_id);

			SET @indiceBase = getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'Indice de base');
		    -- A revoir le calcul
			-- SET @indiceJour = maxBaseIndice(_payroll_configuration_id)/@nbrJour;
			SET @indiceJour = IFNULL(@indiceBase/@nbrJour, 0);
			
			CALL addStagePaymentIndice( _employee_uuid, _payroll_configuration_id,'indice jr', @indiceJour);
			CALL addStagePaymentIndice( _employee_uuid, _payroll_configuration_id,'nbre jrs', @nbrJour);
		
			-- SELECT _sumBaseIndice, maxBaseIndice(_payroll_configuration_id), @nbrJour;
			-- indice reajust = @indiceJour*(tot jrs)
			SET @indice_reajust = IFNULL(@indiceJour*@tot_jrs, 0);
		
			CALL addStagePaymentIndice( _employee_uuid, _payroll_configuration_id,'Indice reajuste', @indice_reajust);
			
			-- tot code
			SET @electricite = getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'electricité');
			SET @autres = getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'autres');
	
			SELECT @indice_reajust, @responsabilite, @electricite, @autres;
			CALL addStagePaymentIndice( _employee_uuid, _payroll_configuration_id, 'tot code', 
				@indice_reajust  + @responsabilite + @electricite + @autres
			);
			
			-- tx paie = @envelopPaie / (somme indice de base)
			IF (_sumBaseIndice = 0) THEN
				SET _sumBaseIndice = 1;
			END IF;

			CALL addStagePaymentIndice( _employee_uuid,_payroll_configuration_id,'tx paie', 
			@envelopPaie/_sumBaseIndice
			);
			-- sal de base
			SET @sal_de_base = getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'tot code')*
				getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'tx paie');


			CALL addStagePaymentIndice( _employee_uuid,_payroll_configuration_id,'brute', IFNULL(@sal_de_base, 0));

			UPDATE employee SET individual_salary = getStagePaymentIndice(_employee_uuid, _payroll_configuration_id, 'brute')
			WHERE uuid = _employee_uuid;

		END LOOP;
	CLOSE curs1;
END$$

DELIMITER ;
